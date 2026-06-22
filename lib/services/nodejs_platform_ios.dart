// lib/services/nodejs_platform_ios.dart
//
// iOS 端 Node.js 实现
// -----------------------------------------------------------------------------
// 通过 platform channel 调 Swift 端 → Swift 端嵌入 NodeMobile.xcframework
//   - 启动：`NodeMobile.start(["node", "main.js", "--native-port", port])`
//   - 停止：调 `node_exit`（NodeMobile 提供）或让进程自然结束
//   - 状态：Swift 端通过 `channel.invokeMethod` 推回 Dart
//
// **运行时不需要下载**：
//   - NodeMobile.xcframework 嵌进 Runner.app
//   - main.js 嵌进 Runner.app/nodejs-project/main.js（workflow 做）
//   - 用户源写到 <Documents>/nodejs-project/src/source/
//
// **HTTP server 还在 Dart 端**：
//   Node.js 通过 `--native-port` 拿到端口，回调 `GET /onCatPawOpenPort` 通知 Dart
//   与 Windows 端共用同一套 dart:io HttpServer

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'nodejs_platform.dart';

class IOSNodeJSPlatform implements NodeJSPlatform {
  IOSNodeJSPlatform({
    required this.onNodeReadyChanged,
    required this.onManagementPortChanged,
    required this.onSpiderPortChanged,
  });

  final ValueNotifier<bool> onNodeReadyChanged;
  final ValueNotifier<int> onManagementPortChanged;
  final ValueNotifier<int> onSpiderPortChanged;

  /// iOS native platform channel
  /// - 在 Swift 端 [NodeJSBridge] 注册同名 channel
  /// - Method: startNodeJS, stopNodeJS, getStatus
  /// - Swift → Dart callback: onNodeExit, onNodeReady
  static const MethodChannel _channel =
      MethodChannel('com.tvbox/flutter/nodejs');

  // 状态（Dart 端自己维护，HTTP server 收通知时更新）
  bool _isRunning = false;
  bool _isNodeReady = false;
  int _nativeServerPort = 0;
  int _managementPort = 0;
  int _spiderPort = 0;

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 15),
  ));

  @override
  bool get isRunning => _isRunning;
  @override
  bool get isNodeReady => _isNodeReady;
  @override
  int get nativeServerPort => _nativeServerPort;
  @override
  int get managementPort => _managementPort;
  @override
  int get spiderPort => _spiderPort;

  /// 初始化：注册 Swift → Dart callback
  void initialize() {
    _channel.setMethodCallHandler((MethodCall call) async {
      try {
        switch (call.method) {
          case 'onNodeExit':
            final code = call.arguments is int
                ? call.arguments as int
                : (call.arguments is Map ? call.arguments['code'] as int? : null);
            print('[IOSNodeJS] Swift 通知: Node.js 退出，code=$code');
            _isRunning = false;
            _isNodeReady = false;
            onNodeReadyChanged.value = false;
            return null;
          case 'onNodeReady':
            print('[IOSNodeJS] Swift 通知: Node.js ready');
            _isNodeReady = true;
            onNodeReadyChanged.value = true;
            return null;
          case 'onError':
            final msg = call.arguments is String
                ? call.arguments
                : call.arguments.toString();
            print('[IOSNodeJS] Swift 错误: $msg');
            return null;
          default:
            print('[IOSNodeJS] 未知 method call from Swift: ${call.method}');
            return null;
        }
      } catch (e, st) {
        print('[IOSNodeJS] 处理 Swift callback 异常: $e\n$st');
        return null;
      }
    });
  }

  // ============================================================
  // 路径
  // ============================================================

  @override
  Future<String> getDocumentsSourcePath() async {
    // iOS 端: <Documents>/nodejs-project/src/source
    // 与 tvbox-Swift-main 保持一致
    final docs = await getApplicationDocumentsDirectory();
    final sourcePath =
        '${docs.path}/nodejs-project/src/source';
    final dir = Directory(sourcePath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return sourcePath;
  }

  // ============================================================
  // 启动 / 停止
  // ============================================================

  @override
  Future<bool> startNodeJS() async {
    if (_isRunning) return true;

    _isNodeReady = false;
    _spiderPort = 0;
    _managementPort = 0;
    onNodeReadyChanged.value = false;
    onManagementPortChanged.value = 0;
    onSpiderPortChanged.value = 0;

    final sourcePath = await getDocumentsSourcePath();
    final nativePort = _nativeServerPort;

    print('[IOSNodeJS] 调 Swift 启动 Node.js, nativePort=$nativePort, '
        'sourcePath=$sourcePath');

    try {
      // 调 Swift 端启动
      // Swift 端会:
      //   1. 在 mainBundle 找 nodejs-project/main.js
      //   2. 启动 GCDWebServer（或信任 Dart 端 HTTP server）
      //   3. setenv(NODE_PATH, sourcePath)
      //   4. node_start(["node", "--security-revert=CVE-2023-46809",
      //                  "main.js", "--native-port", "$nativePort"])
      final result = await _channel.invokeMethod<bool>('startNodeJS', {
        'nativePort': nativePort,
        'sourcePath': sourcePath,
      });
      if (result == true) {
        _isRunning = true;
        print('[IOSNodeJS] Swift 启动成功');
        return await waitForNodeReady();
      }
      print('[IOSNodeJS] Swift 启动失败');
      return false;
    } on PlatformException catch (e) {
      print('[IOSNodeJS] startNodeJS PlatformException: ${e.code}/${e.message}');
      return false;
    } catch (e) {
      print('[IOSNodeJS] startNodeJS 异常: $e');
      return false;
    }
  }

  @override
  void stopNodeJS() {
    if (!_isRunning) return;
    _isRunning = false;
    _isNodeReady = false;
    _nativeServerPort = 0;
    _spiderPort = 0;
    _managementPort = 0;
    onNodeReadyChanged.value = false;
    onManagementPortChanged.value = 0;
    onSpiderPortChanged.value = 0;

    _channel.invokeMethod('stopNodeJS').catchError((e) {
      print('[IOSNodeJS] stopNodeJS 异常: $e');
      return null;
    });
    print('[IOSNodeJS] Node.js 已停止');
  }

  @override
  void forceResetRunningState() {
    _isRunning = false;
    _isNodeReady = false;
    _nativeServerPort = 0;
    _spiderPort = 0;
    _managementPort = 0;
    onNodeReadyChanged.value = false;
    onManagementPortChanged.value = 0;
    onSpiderPortChanged.value = 0;
    print('[IOSNodeJS] 强制重置运行状态');
  }

  // ============================================================
  // 状态同步（Dart 端 HTTP server 收到 Node.js 通知时调）
  // ============================================================

  /// HTTP server 收到 Node.js 的 `/onCatPawOpenPort?port=&type=` 时调用
  void onPortReceived(int port, String type) {
    print('[IOSNodeJS] 收到端口通知: $port, 类型: $type');
    if (type == 'management') {
      _managementPort = port;
      onManagementPortChanged.value = port;
    } else {
      _spiderPort = port;
      onSpiderPortChanged.value = port;
    }
  }

  /// HTTP server 收到 Node.js 的 `/onMessage` 时调用
  void onMessage(String message) {
    print('[IOSNodeJS] 收到 Node.js 消息: $message');
    if (message == 'ready') {
      _isNodeReady = true;
      onNodeReadyChanged.value = true;
    }
  }

  /// 由 NodeJSManager 顶层 HTTP server 启动后设置
  void setNativeServerPort(int port) {
    _nativeServerPort = port;
  }

  @override
  Future<bool> waitForNodeReady() async {
    if (_isNodeReady) return true;
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      if (_isNodeReady) return true;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    print('[IOSNodeJS] 等待 Node.js 就绪超时');
    return _isNodeReady;
  }

  @override
  Future<bool> waitForSpiderPort() async {
    if (_spiderPort > 0) return true;
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      if (_spiderPort > 0) return true;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    print('[IOSNodeJS] 等待 Spider 端口超时');
    return _spiderPort > 0;
  }

  // ============================================================
  // 源管理
  // ============================================================

  @override
  Future<(bool success, String? message)> loadSource(
      String urlString) async {
    if (urlString.isEmpty) return (false, 'URL 为空');

    var normalizedUrl = urlString;
    if (normalizedUrl.endsWith('.js.md5')) {
      normalizedUrl = normalizedUrl.substring(0, normalizedUrl.length - 4);
      print('[IOSNodeJS] 规范化 URL（移除 .md5 后缀）: $normalizedUrl');
    }

    final uri = Uri.tryParse(normalizedUrl);
    if (uri == null) return (false, '无效的 URL');

    final sourcePath = await getDocumentsSourcePath();
    final indexJSPath = '$sourcePath/index.js';
    final indexMd5Path = '$sourcePath/index.js.md5';
    final configJSPath = '$sourcePath/index.config.js';
    final configMd5Path = '$sourcePath/index.config.js.md5';

    final localJSExists = await File(indexJSPath).exists();
    final localMd5Exists = await File(indexMd5Path).exists();
    print('[IOSNodeJS] 缓存检查: index.js 存在=$localJSExists, '
        'index.js.md5 存在=$localMd5Exists');

    if (localJSExists && localMd5Exists) {
      try {
        final md5Url = '$normalizedUrl.md5';
        String? remoteMd5;
        try {
          final response = await _dio.get<String>(
            md5Url,
            options: Options(responseType: ResponseType.plain),
          );
          if (response.statusCode == 200 && response.data != null) {
            remoteMd5 = response.data!.trim();
          }
        } on DioException catch (e) {
          print('[IOSNodeJS] 远程 MD5 下载失败: ${e.message}');
        }

        if (remoteMd5 != null && remoteMd5.isNotEmpty) {
          final localMd5Content =
              await File(indexMd5Path).readAsString();
          final localMd5 = localMd5Content.trim();
          if (localMd5 == remoteMd5) {
            print('[IOSNodeJS] MD5 匹配！使用缓存源，跳过下载');
            return await _sendLoadCommandToNodeJS(sourcePath);
          }
        }
      } catch (e) {
        print('[IOSNodeJS] MD5 缓存检查异常: $e');
      }
    }

    try {
      final jsResponse = await _dio.get<List<int>>(
        normalizedUrl,
        options: Options(responseType: ResponseType.bytes),
      );
      if (jsResponse.statusCode == 200 && jsResponse.data != null) {
        final jsData = jsResponse.data!;
        print('[IOSNodeJS] 主源文件已下载，大小: ${jsData.length} 字节');

        String? md5Data;
        try {
          final md5Response = await _dio.get<String>(
            '$normalizedUrl.md5',
            options: Options(responseType: ResponseType.plain),
          );
          if (md5Response.statusCode == 200 && md5Response.data != null) {
            md5Data = md5Response.data!.trim();
          }
        } on DioException catch (_) {}

        List<int>? configData;
        try {
          final configUrl =
              normalizedUrl.replaceAll('/index.js', '/index.config.js');
          final configResponse = await _dio.get<List<int>>(
            configUrl,
            options: Options(responseType: ResponseType.bytes),
          );
          if (configResponse.statusCode == 200 &&
              configResponse.data != null) {
            configData = configResponse.data!;
          }
        } on DioException catch (_) {}

        if (md5Data != null && md5Data.isNotEmpty) {
          final actualMd5 = md5.convert(jsData).toString();
          if (actualMd5 != md5Data) return (false, 'MD5 校验失败');
        }

        final sourceDir = Directory(sourcePath);
        if (!await sourceDir.exists()) await sourceDir.create(recursive: true);
        await File(indexJSPath).writeAsBytes(jsData);
        if (md5Data != null) {
          await File(indexMd5Path).writeAsString(md5Data);
        }
        if (configData != null) {
          await File(configJSPath).writeAsBytes(configData);
        } else {
          await File(configJSPath)
              .writeAsString('module.exports = { color: [] };');
        }

        return await _sendLoadCommandToNodeJS(sourcePath);
      }
      return (false, '下载源文件失败 (状态码: ${jsResponse.statusCode})');
    } on DioException catch (e) {
      return (false, '下载源文件失败: ${e.message}');
    }
  }

  @override
  Future<bool> deleteSource() async {
    final sourcePath = await getDocumentsSourcePath();
    final dir = Directory(sourcePath);
    if (await dir.exists()) {
      try {
        await dir.delete(recursive: true);
      } catch (e) {
        return false;
      }
    }
    _spiderPort = 0;
    onSpiderPortChanged.value = 0;
    return true;
  }

  Future<(bool success, String? message)> _sendLoadCommandToNodeJS(
      String path) async {
    if (_managementPort <= 0) {
      return (false, 'Management 端口未就绪，请先启动 Node.js');
    }
    try {
      final response = await _dio.post(
        'http://127.0.0.1:$_managementPort/source/loadPath',
        data: {'path': path},
        options: Options(
          responseType: ResponseType.json,
          contentType: 'application/json',
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
        ),
      );
      if (response.statusCode != null && response.statusCode! >= 400) {
        return (false, '加载失败: HTTP ${response.statusCode}');
      }
      return (true, '源加载成功');
    } on DioException catch (e) {
      return (false, '加载请求失败: ${e.message}');
    }
  }

  // ============================================================
  // 运行时检查（iOS 永远 true）
  // ============================================================

  @override
  Future<bool> isNodeRuntimeInstalled() async {
    // iOS: NodeMobile.xcframework 嵌进 bundle，永远 true
    return true;
  }

  @override
  Future<void> downloadAndExtractNodeRuntime(
    NodeDownloadConfig cfg, {
    void Function(double progress)? onProgress,
  }) async {
    // iOS 不需要下载运行时
    if (onProgress != null) onProgress(1.0);
    return;
  }
}

/// 工具：从 url 解析 host（用于在 iOS 上传 source path 时的归一化）
class IOSNodeJSPlatformHelper {
  /// 从 path 提取文件名
  static String basename(String path) {
    return path.split(Platform.pathSeparator).last;
  }

  /// Node.js HTTP 响应解析
  static Map<String, dynamic> parseResponse(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }
}
