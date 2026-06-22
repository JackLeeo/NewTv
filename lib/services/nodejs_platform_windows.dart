// lib/services/nodejs_platform_windows.dart
//
// Windows 端 Node.js 实现
// -----------------------------------------------------------------------------
// 启动外部 node.exe 进程（Process.start）。
// - node.exe 首次启动按需从 npmmirror 下载 zip
// - main.js 从 rootBundle 解压到 <AppSupport>/nodejs/main.js
// - NODE_PATH 指向 <Documents>/nodejs/source
// - 本地 HTTP server (dart:io) 接收 Node.js 的端口通知 + ready 消息

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'nodejs_platform.dart';

class WindowsNodeJSPlatform implements NodeJSPlatform {
  WindowsNodeJSPlatform({
    required this.onNodeReadyChanged,
    required this.onManagementPortChanged,
    required this.onSpiderPortChanged,
  });

  /// 通知 Dart 端 HTTP server 层：Node.js ready 状态变化
  final ValueNotifier<bool> onNodeReadyChanged;
  final ValueNotifier<int> onManagementPortChanged;
  final ValueNotifier<int> onSpiderPortChanged;

  static const String _bundledNodeVersionMeta =
      'assets/nodejs-runtime/version.json';
  static const String _bundledMainJs = 'assets/nodejs-project/dist/main.js';
  static const int _maxStartupWaitSeconds = 30;

  NodeDownloadConfig? _nodeDownloadConfig;
  NodeDownloadConfig? get nodeDownloadConfig => _nodeDownloadConfig;

  // UI 进度回调
  final ValueNotifier<double?> nodeDownloadProgress = ValueNotifier(null);
  final ValueNotifier<String?> nodeDownloadStatus = ValueNotifier(null);

  bool _isRunning = false;
  bool _isNodeReady = false;
  int _nativeServerPort = 0;
  int _managementPort = 0;
  int _spiderPort = 0;
  Process? _nodeProcess;

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

  // ============================================================
  // 路径
  // ============================================================

  Future<String> _getNodeRuntimeDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}node-runtime');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  Future<String> _getBundledNodeExePath() async {
    final dir = await _getNodeRuntimeDir();
    return '$dir${Platform.pathSeparator}node.exe';
  }

  Future<String> _getNodeJsDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}nodejs');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  Future<String> _getLocalScriptPath() async {
    final dir = await _getNodeJsDir();
    return '$dir${Platform.pathSeparator}main.js';
  }

  @override
  Future<String> getDocumentsSourcePath() async {
    final docs = await getApplicationDocumentsDirectory();
    final sourcePath =
        '${docs.path}${Platform.pathSeparator}nodejs${Platform.pathSeparator}source';
    final dir = Directory(sourcePath);
    if (!await dir.exists()) await dir.create(recursive: true);
    return sourcePath;
  }

  // ============================================================
  // 运行时准备
  // ============================================================

  Future<NodeDownloadConfig> _loadNodeDownloadConfig() async {
    if (_nodeDownloadConfig != null) return _nodeDownloadConfig!;
    final raw = await rootBundle.loadString(_bundledNodeVersionMeta);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final cfg = NodeDownloadConfig.fromJson(json);
    _nodeDownloadConfig = cfg;
    return cfg;
  }

  @override
  Future<bool> isNodeRuntimeInstalled() async {
    final exePath = await _getBundledNodeExePath();
    final exeFile = File(exePath);
    if (!await exeFile.exists()) return false;
    return (await exeFile.length()) > 1000000;
  }

  /// 确保 node.exe 已就绪（缺失则下载 + 解压）
  /// 返回 node.exe 的绝对路径
  Future<String> _ensureNodeRuntimeReady() async {
    final cfg = await _loadNodeDownloadConfig();
    final exePath = await _getBundledNodeExePath();
    final exeFile = File(exePath);
    if (await exeFile.exists() && (await exeFile.length()) > 1000000) {
      print('[WinNodeJS] node.exe 已存在: $exePath '
          '(${(await exeFile.length()) ~/ 1024} KB)');
      return exePath;
    }
    print('[WinNodeJS] node.exe 不存在，自动下载 Node.js ${cfg.version}...');
    await downloadAndExtractNodeRuntime(cfg);
    return exePath;
  }

  @override
  Future<void> downloadAndExtractNodeRuntime(
    NodeDownloadConfig cfg, {
    void Function(double progress)? onProgress,
  }) async {
    nodeDownloadStatus.value = 'downloading';
    nodeDownloadProgress.value = 0.0;
    if (onProgress != null) onProgress(0.0);

    final tmpDir = await getTemporaryDirectory();
    final tmpZipPath =
        '${tmpDir.path}${Platform.pathSeparator}node-${cfg.version}.zip';

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 5),
      responseType: ResponseType.bytes,
    ));

    print('[WinNodeJS] 下载 Node.js zip: ${cfg.downloadUrl}');
    final bytes = <int>[];
    int received = 0;
    int? total;
    try {
      final response = await dio.get<ResponseBody>(
        cfg.downloadUrl,
        options: Options(responseType: ResponseType.stream),
      );
      final body = response.data;
      if (body == null) throw Exception('下载响应体为空');
      final contentLength = body.contentLength;
      if (contentLength != null && contentLength > 0) total = contentLength;
      await for (final chunk in body.stream) {
        bytes.addAll(chunk);
        received += chunk.length;
        if (total != null) {
          final p = received / total;
          nodeDownloadProgress.value = p;
          if (onProgress != null) onProgress(p);
        }
      }
    } on DioException catch (e) {
      nodeDownloadStatus.value = 'error';
      nodeDownloadProgress.value = null;
      throw Exception('下载 Node.js 失败: ${e.message}');
    } catch (e) {
      nodeDownloadStatus.value = 'error';
      nodeDownloadProgress.value = null;
      rethrow;
    }

    if (onProgress != null) onProgress(1.0);
    nodeDownloadProgress.value = 1.0;

    print('[WinNodeJS] 下载完成: ${bytes.length} 字节，写入临时文件');
    final tmpZip = File(tmpZipPath);
    await tmpZip.writeAsBytes(bytes, flush: true);

    nodeDownloadStatus.value = 'extracting';
    print('[WinNodeJS] 解压 Node.js zip...');
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      nodeDownloadStatus.value = 'error';
      throw Exception('解压 zip 失败: $e');
    }
    final exeFile = archive.files.firstWhere(
      (f) => f.name == cfg.exeRelativePathInZip,
      orElse: () => throw Exception(
          '在 zip 中未找到 ${cfg.exeRelativePathInZip}'),
    );

    final runtimeDir = Directory(await _getNodeRuntimeDir());
    if (!await runtimeDir.exists()) await runtimeDir.create(recursive: true);
    final destExe = File(await _getBundledNodeExePath());
    await destExe.writeAsBytes(exeFile.content as List<int>, flush: true);
    print(
        '[WinNodeJS] node.exe 已就绪: ${destExe.path} (${exeFile.size} 字节)');

    try {
      await tmpZip.delete();
    } catch (_) {}

    nodeDownloadStatus.value = 'done';
    Future.delayed(const Duration(seconds: 2), () {
      if (nodeDownloadStatus.value == 'done') {
        nodeDownloadStatus.value = null;
        nodeDownloadProgress.value = null;
      }
    });
  }

  /// 从 rootBundle 解压 main.js 到本地磁盘
  Future<String> _ensureScriptReady() async {
    final localPath = await _getLocalScriptPath();
    final localFile = File(localPath);
    if (await localFile.exists() && (await localFile.length()) > 0) {
      return localPath;
    }
    try {
      print('[WinNodeJS] 从 rootBundle 解压 main.js...');
      final data = await rootBundle.load(_bundledMainJs);
      final bytes = data.buffer.asUint8List();
      await localFile.writeAsBytes(bytes, flush: true);
      print('[WinNodeJS] main.js 已就绪: $localPath (${bytes.length} 字节)');
      return localPath;
    } catch (e) {
      print('[WinNodeJS] 解压 main.js 失败: $e');
      return '';
    }
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

    final String nodeExePath;
    try {
      nodeExePath = await _ensureNodeRuntimeReady();
    } catch (e) {
      print('[WinNodeJS] Node.js 运行时准备失败: $e');
      return false;
    }
    final nodeExe = File(nodeExePath);
    if (!await nodeExe.exists()) {
      print('[WinNodeJS] Node.js 可执行文件不存在: $nodeExePath');
      return false;
    }

    final scriptPath = await _ensureScriptReady();
    if (scriptPath.isEmpty) {
      print('[WinNodeJS] 无法准备 Node.js 脚本');
      return false;
    }

    print('[WinNodeJS] 启动 Node.js，node: $nodeExePath, '
        'script: $scriptPath, nativeServerPort: $_nativeServerPort');

    final sourcePath = await getDocumentsSourcePath();

    try {
      final args = <String>[
        '--security-revert=CVE-2023-46809',
        scriptPath,
      ];
      if (_nativeServerPort > 0) {
        args.addAll(['--native-port', _nativeServerPort.toString()]);
      }

      _nodeProcess = await Process.start(
        nodeExePath,
        args,
        environment: {'NODE_PATH': sourcePath},
        workingDirectory: File(scriptPath).parent.path,
      );

      _isRunning = true;

      _nodeProcess!.stdout.listen((data) {
        final output = utf8.decode(data, allowMalformed: true).trim();
        if (output.isNotEmpty) print('[NodeJS stdout] $output');
      });
      _nodeProcess!.stderr.listen((data) {
        final output = utf8.decode(data, allowMalformed: true).trim();
        if (output.isNotEmpty) print('[NodeJS stderr] $output');
      });
      _nodeProcess!.exitCode.then((exitCode) {
        print('[WinNodeJS] Node.js 进程退出，退出码: $exitCode');
        _isRunning = false;
        _isNodeReady = false;
        onNodeReadyChanged.value = false;
      });

      return await waitForNodeReady();
    } catch (e) {
      print('[WinNodeJS] 启动 Node.js 失败: $e');
      _isRunning = false;
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
    _nodeProcess?.kill();
    _nodeProcess = null;
    print('[WinNodeJS] Node.js 已停止');
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
    _nodeProcess?.kill();
    _nodeProcess = null;
    print('[WinNodeJS] 强制重置运行状态');
  }

  // ============================================================
  // 状态同步（由 NodeJSManager 顶层 HTTP server 调）
  // ============================================================

  /// HTTP server 收到 Node.js 的 `/onCatPawOpenPort?port=&type=` 时调用
  void onPortReceived(int port, String type) {
    print('[WinNodeJS] 收到端口通知: $port, 类型: $type');
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
    print('[WinNodeJS] 收到 Node.js 消息: $message');
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
    final deadline = DateTime.now()
        .add(const Duration(seconds: _maxStartupWaitSeconds));
    while (DateTime.now().isBefore(deadline)) {
      if (_isNodeReady) return true;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    print('[WinNodeJS] 等待 Node.js 就绪超时');
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
    print('[WinNodeJS] 等待 Spider 端口超时');
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
      print('[WinNodeJS] 规范化 URL（移除 .md5 后缀）: $normalizedUrl');
    }

    final uri = Uri.tryParse(normalizedUrl);
    if (uri == null) return (false, '无效的 URL');

    final sourcePath = await getDocumentsSourcePath();
    final indexJSPath =
        '$sourcePath${Platform.pathSeparator}index.js';
    final indexMd5Path =
        '$sourcePath${Platform.pathSeparator}index.js.md5';
    final configJSPath =
        '$sourcePath${Platform.pathSeparator}index.config.js';
    final configMd5Path =
        '$sourcePath${Platform.pathSeparator}index.config.js.md5';

    final localJSExists = await File(indexJSPath).exists();
    final localMd5Exists = await File(indexMd5Path).exists();
    print(
        '[WinNodeJS] 缓存检查: index.js 存在=$localJSExists, index.js.md5 存在=$localMd5Exists');

    if (localJSExists && localMd5Exists) {
      try {
        final md5Url = '$normalizedUrl.md5';
        print('[WinNodeJS] 缓存检查: 下载远程 MD5: $md5Url');
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
          print('[WinNodeJS] 远程 MD5 下载失败: ${e.message}');
        }

        if (remoteMd5 != null && remoteMd5.isNotEmpty) {
          final localMd5Content =
              await File(indexMd5Path).readAsString();
          final localMd5 = localMd5Content.trim();
          print(
              '[WinNodeJS] 缓存 MD5 比较: 本地=$localMd5, 远程=$remoteMd5');
          if (localMd5 == remoteMd5) {
            print('[WinNodeJS] MD5 匹配！使用缓存源，跳过下载');
            return await _sendLoadCommandToNodeJS(sourcePath);
          }
        }
      } catch (e) {
        print('[WinNodeJS] MD5 缓存检查异常: $e');
      }
    }

    Uint8List? jsData;
    String? md5Data;
    Uint8List? configData;
    String? configMd5Data;

    try {
      final jsResponse = await _dio.get<List<int>>(
        normalizedUrl,
        options: Options(responseType: ResponseType.bytes),
      );
      if (jsResponse.statusCode == 200 && jsResponse.data != null) {
        jsData = Uint8List.fromList(jsResponse.data!);
        print(
            '[WinNodeJS] 主源文件已下载，大小: ${jsData.length} 字节');
      } else {
        return (
          false,
          '下载源文件失败 (状态码: ${jsResponse.statusCode})'
        );
      }
    } on DioException catch (e) {
      return (false, '下载源文件失败: ${e.message}');
    }

    try {
      final md5Response = await _dio.get<String>(
        '$normalizedUrl.md5',
        options: Options(responseType: ResponseType.plain),
      );
      if (md5Response.statusCode == 200 && md5Response.data != null) {
        md5Data = md5Response.data!.trim();
      }
    } on DioException catch (e) {
      print('[WinNodeJS] MD5 下载失败（可选）: ${e.message}');
    }

    try {
      final configUrl =
          normalizedUrl.replaceAll('/index.js', '/index.config.js');
      final configResponse = await _dio.get<List<int>>(
        configUrl,
        options: Options(responseType: ResponseType.bytes),
      );
      if (configResponse.statusCode == 200 &&
          configResponse.data != null) {
        configData = Uint8List.fromList(configResponse.data!);
      }
    } on DioException catch (e) {
      print('[WinNodeJS] 配置下载失败（可选）: ${e.message}');
    }

    if (configData != null) {
      try {
        final configUrl =
            normalizedUrl.replaceAll('/index.js', '/index.config.js');
        final configResponse = await _dio.get<String>(
          '$configUrl.md5',
          options: Options(responseType: ResponseType.plain),
        );
        if (configResponse.statusCode == 200 &&
            configResponse.data != null) {
          configMd5Data = configResponse.data!.trim();
        }
      } on DioException catch (_) {}
    }

    if (md5Data != null && md5Data.isNotEmpty) {
      final actualMd5 = md5.convert(jsData!).toString();
      if (actualMd5 != md5Data) {
        return (false, 'MD5 校验失败');
      }
      print('[WinNodeJS] 下载的源文件 MD5 校验通过');
    }

    final sourceDir = Directory(sourcePath);
    if (!await sourceDir.exists()) await sourceDir.create(recursive: true);
    await File(indexJSPath).writeAsBytes(jsData!);
    if (md5Data != null) {
      await File(indexMd5Path).writeAsString(md5Data);
    }
    if (configData != null) {
      await File(configJSPath).writeAsBytes(configData);
      if (configMd5Data != null) {
        await File(configMd5Path).writeAsString(configMd5Data);
      }
    } else {
      await File(configJSPath)
          .writeAsString('module.exports = { color: [] };');
    }

    return await _sendLoadCommandToNodeJS(sourcePath);
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
}
