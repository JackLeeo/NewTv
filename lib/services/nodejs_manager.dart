// lib/services/nodejs_manager.dart
//
// Node.js 管理器 - **跨平台单例**
// -----------------------------------------------------------------------------
// 三端用各自的 Node.js 嵌入方案：
//   - **Windows**: Process.start(node.exe) + 按需下载 zip
//   - **iOS**:     platform channel → Swift → NodeMobile.xcframework
//   - **Android**: platform channel → Kotlin → libnode（占位，未实现）
//
// 跨端通用的部分（HTTP server 收通知、UI ValueNotifier、源管理 HTTP 调用）留在
// 本文件。各端平台实现在 [nodejs_platform_*.dart] 里。
//
// **目录布局**：
// ```
//   <AppSupport>/node-runtime/     # Windows 专用：node.exe
//   <AppSupport>/nodejs/main.js    # Windows: rootBundle 解压
//   <Documents>/nodejs/source/     # Windows 源目录
//   <Documents>/nodejs-project/src/source/  # iOS 源目录
// ```

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'nodejs_platform.dart';
import 'nodejs_platform_android.dart';
import 'nodejs_platform_ios.dart';
import 'nodejs_platform_windows.dart';

class NodeJSManager {
  static final NodeJSManager _instance = NodeJSManager._internal();
  static NodeJSManager get instance => _instance;

  // ============================================================
  // 平台实现
  // ============================================================
  late final NodeJSPlatform _platform;
  NodeJSPlatform get platform => _platform;

  // UI ValueNotifier
  final ValueNotifier<double?> nodeDownloadProgress = ValueNotifier(null);
  final ValueNotifier<String?> nodeDownloadStatus = ValueNotifier(null);

  // HTTP server 状态（跨端统一）
  HttpServer? _httpServer;
  int _nativeServerPort = 0;
  int get nativeServerPort => _nativeServerPort;

  // HTTP server 层 → 平台实现的桥接
  final ValueNotifier<bool> _nodeReadyBridge = ValueNotifier(false);
  final ValueNotifier<int> _managementPortBridge = ValueNotifier(0);
  final ValueNotifier<int> _spiderPortBridge = ValueNotifier(0);

  NodeJSManager._internal() {
    if (Platform.isWindows) {
      _platform = WindowsNodeJSPlatform(
        onNodeReadyChanged: _nodeReadyBridge,
        onManagementPortChanged: _managementPortBridge,
        onSpiderPortChanged: _spiderPortBridge,
      );
    } else if (Platform.isIOS) {
      final ios = IOSNodeJSPlatform(
        onNodeReadyChanged: _nodeReadyBridge,
        onManagementPortChanged: _managementPortBridge,
        onSpiderPortChanged: _spiderPortBridge,
      );
      ios.initialize();
      _platform = ios;
    } else if (Platform.isAndroid) {
      _platform = AndroidNodeJSPlatform(
        onNodeReadyChanged: _nodeReadyBridge,
        onManagementPortChanged: _managementPortBridge,
        onSpiderPortChanged: _spiderPortBridge,
      );
    } else {
      throw UnsupportedError('Node.js 集成不支持当前平台: ${Platform.operatingSystem}');
    }
  }

  // ============================================================
  // 公开 API（透传到 platform 实现）
  // ============================================================

  bool get isRunning => _platform.isRunning;
  bool get isNodeReady => _platform.isNodeReady;
  int get managementPort => _platform.managementPort;
  int get spiderPort => _platform.spiderPort;

  /// 启动 Node.js
  ///
  /// 1. 启动 Dart 端 HTTP server（收 Node.js 通知）
  /// 2. 把 HTTP server 端口注入 platform 实现
  /// 3. 调 platform.startNodeJS()
  Future<bool> startNodeJS() async {
    // 1. 起 HTTP server
    if (_httpServer == null) {
      final started = await _startLocalWebServer();
      if (!started) return false;
    }
    // 2. 注入端口
    _platform.setNativeServerPort(_nativeServerPort);
    // 3. 启动
    return await _platform.startNodeJS();
  }

  void stopNodeJS() {
    _platform.stopNodeJS();
    _stopHttpServer();
  }

  void forceResetRunningState() {
    _platform.forceResetRunningState();
    _stopHttpServer();
  }

  Future<bool> waitForNodeReady() => _platform.waitForNodeReady();
  Future<bool> waitForSpiderPort() => _platform.waitForSpiderPort();

  Future<(bool success, String? message)> loadSource(String urlString) =>
      _platform.loadSource(urlString);

  Future<bool> deleteSource() => _platform.deleteSource();

  Future<String> getDocumentsSourcePath() => _platform.getDocumentsSourcePath();

  /// 当前平台的 NodeDownloadConfig（仅 Windows 端有值）
  NodeDownloadConfig? get nodeDownloadConfig {
    if (_platform is WindowsNodeJSPlatform) {
      return (_platform as WindowsNodeJSPlatform).nodeDownloadConfig;
    }
    return null;
  }

  /// 公开 API：加载 Node.js 下载配置（从 rootBundle 读 version.json）
  ///
  /// **跨端统一**：三端都会读同一个 version.json，但只有 Windows 用得上。
  static Future<NodeDownloadConfig> loadNodeDownloadConfigStatic() async {
    final raw = await rootBundle
        .loadString('assets/nodejs-runtime/version.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return NodeDownloadConfig.fromJson(json);
  }

  /// 检查本地端口是否可达
  ///
  /// 用于 `handleSceneActive` 重连判断：spiderPort / managementPort 还活着没。
  Future<bool> checkLocalPort(int port) async {
    if (port <= 0) return false;
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 2),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 通过 management 端口让 Node.js 重新加载源
  ///
  /// 调用方需要先确保源文件已经写到 `<Documents>/nodejs/source/`
  Future<bool> reloadSourceViaManagementPort(int port) async {
    if (port <= 0) return false;
    try {
      final sourcePath = await getDocumentsSourcePath();
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        sendTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ));
      final resp = await dio.post(
        'http://127.0.0.1:$port/source/loadPath',
        data: {'path': sourcePath},
        options: Options(
          contentType: 'application/json',
          responseType: ResponseType.plain,
        ),
      );
      return resp.statusCode != null && resp.statusCode! < 400;
    } catch (e) {
      print('[NodeJSManager] reloadSourceViaManagementPort 失败: $e');
      return false;
    }
  }

  /// Windows 专用：检查 node.exe 是否就绪
  Future<bool> isNodeRuntimeInstalled() => _platform.isNodeRuntimeInstalled();

  /// Windows 专用：下载 + 解压 Node.js runtime
  /// iOS / Android 直接返回
  Future<void> downloadAndExtractNodeRuntime(
    NodeDownloadConfig cfg, {
    void Function(double progress)? onProgress,
  }) =>
      _platform.downloadAndExtractNodeRuntime(
        cfg,
        onProgress: onProgress,
      );

  // ============================================================
  // 本地 HTTP 服务器（跨端统一用 dart:io）
  // ============================================================

  /// 启动本地 HTTP 服务器接收 Node.js 通知
  Future<bool> _startLocalWebServer() async {
    try {
      _httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _nativeServerPort = _httpServer!.port;
      print('[NodeJSManager] 本地通知服务器已启动，端口: $_nativeServerPort');

      _httpServer!.listen((HttpRequest request) {
        _handleRequest(request);
      });
      return true;
    } catch (e) {
      print('[NodeJSManager] 本地 Web 服务器启动失败: $e');
      return false;
    }
  }

  void _stopHttpServer() {
    _httpServer?.close(force: true);
    _httpServer = null;
    _nativeServerPort = 0;
  }

  void _handleRequest(HttpRequest request) {
    final path = request.uri.path;
    final query = request.uri.queryParameters;

    if (path == '/onCatPawOpenPort' && request.method == 'GET') {
      final portStr = query['port'];
      final typeStr = query['type'] ?? 'spider';
      if (portStr != null) {
        final port = int.tryParse(portStr) ?? 0;
        _platform.onPortReceived(port, typeStr);
      }
      request.response
        ..write('OK')
        ..close();
    } else if (path == '/onMessage' && request.method == 'POST') {
      final contentLength = request.contentLength;
      if (contentLength > 0 && contentLength <= 1024 * 1024) {
        final builder = BytesBuilder();
        request.listen(
          (data) => builder.add(data),
          onDone: () {
            try {
              final body = utf8.decode(builder.toBytes());
              final json = jsonDecode(body) as Map<String, dynamic>;
              final message = json['message'] as String?;
              if (message != null) {
                _platform.onMessage(message);
              }
            } catch (e) {
              print('[NodeJSManager] 解析消息失败: $e');
            }
            request.response
              ..write('OK')
              ..close();
          },
          onError: (e) {
            print('[NodeJSManager] 读取消息失败: $e');
            request.response
              ..statusCode = HttpStatus.badRequest
              ..close();
          },
        );
      } else {
        request.response
          ..write('OK')
          ..close();
      }
    } else {
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
    }
  }
}

/// 公开版本，供 UI 层访问下载配置
///
/// Windows 端使用。其他端直接返回 Windows 端的 version.json（但用不上）
Future<NodeDownloadConfig> loadNodeDownloadConfigPublic() async {
  final raw = await rootBundle
      .loadString('assets/nodejs-runtime/version.json');
  final json = jsonDecode(raw) as Map<String, dynamic>;
  return NodeDownloadConfig.fromJson(json);
}
