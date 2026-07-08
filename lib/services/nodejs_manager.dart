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

import 'app_log.dart';
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

  // **2026-07-08 删 resetPlatformStateForRestart**:
  // 6988e13 引入的 force_restart 路径 (调本方法清 Swift isRunning + startNodeJS
  // 重启 Node.js) 实测无效. iOS NodeMobile 是 embed library, V8 单例, 第二次
  // node_start 调会卡 V8 init 阶段, node.log 0 行新 boot 记录, 新 Node.js
  // 永远起不来. 而且老 Node.js 通常只是 iOS 后台冻结 (74s 后台不触发 SIGKILL),
  // 实际还活着, 端口冲突让新 Node.js EADDRINUSE 立即失败.
  //
  // 改为: app_state.dart 不再调本方法, 改用 6×10s=60s 长重试给 iOS 自动解冻
  // 老 Node.js 时间. 重试仍 fail 后弹窗让用户手动重启 app.

  void forceResetRunningState() {
    // **关键**: 不停 Dart HTTP server. Node.js 死了之后, iOS 唤醒
    // 触发 handleSceneActive, 如果停掉 Dart HTTP server 然后调
    // startNodeJS 重启 Node.js, Node.js 启动后通过 onCatPawOpenPort
    // 通知 Dart 新端口 — 但 Dart HTTP server 刚停/正在重启, 新连接
    // 进不来, 通知丢失, Dart 永远拿不到新端口, verify 永远失败.
    //
    // HTTP server 必须一直跑, Node.js 任何时候启动都能通知到.
    // 之前 79177e1 行为就是只清状态不停 server, 才是对的.
    AppLog.instance.nodejs('forceReset', fields: {
      'beforeSpiderPort': _platform.spiderPort,
      'beforeMgmtPort': _platform.managementPort,
      'beforeIsRunning': _platform.isRunning,
      'reason': '保留 HTTP server, 只清状态',
    });
    _platform.forceResetRunningState();
    AppLog.instance.nodejs('forceReset_done', fields: {
      'afterSpiderPort': _platform.spiderPort,
      'afterMgmtPort': _platform.managementPort,
      'afterIsRunning': _platform.isRunning,
    });
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
    final startAt = DateTime.now();
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 2),
      );
      socket.destroy();
      AppLog.instance.ports(
        'check_local_port_ok',
        ok: true,
        fields: {
          'port': port,
          'elapsedMs': DateTime.now().difference(startAt).inMilliseconds,
        },
      );
      return true;
    } catch (e) {
      AppLog.instance.ports(
        'check_local_port_fail',
        ok: false,
        error: e.toString(),
        fields: {
          'port': port,
          'elapsedMs': DateTime.now().difference(startAt).inMilliseconds,
        },
      );
      return false;
    }
  }

  /// 真实 HTTP 探测 Node.js 源是否已加载
  ///
  /// **关键**：区别于 [checkLocalPort] 只用 Socket.connect 探测端口。
  /// iOS 后台冻结 Node.js 进程时，loopback 端口探测可能假阳性（OS 接受
  /// 新 TCP 连接但 Spider 服务实际不响应），导致 handleSceneActive 误判
  /// "端口通" 直接 return，错过 reload 源的时机。
  ///
  /// 用 dio 发真实 HTTP GET 到 mgmtServer 的 `/source/status` 端点
  /// （main.js 实现），验证返回 `{sourceLoaded:true, ...}` 才算
  /// Node.js 真的健康。
  ///
  /// **2026-07-08 修复端口错 bug**:
  /// 旧版 verifySpiderService(int spiderPort) 调 `http://127.0.0.1:9988/source/status`
  /// 永远 404, 因为 `/source/status` 是 **mgmtServer 端点**, 监听在
  /// managementPort (e.g. 52274), 不是 spiderPort (9988). spiderServer
  /// 是 catServerFactory 创建的, 路由由 source/index.js 注册, 不会暴露
  /// `/source/status`. 改用 managementPort 后 8ms 404 -> 8ms 200,
  /// 消除 10s 兜底 reload_no_new_port.
  /// 2s 超时避免锁屏切回时长时间卡住。
  Future<bool> verifySourceLoaded(int managementPort) async {
    if (managementPort <= 0) {
      AppLog.instance.verify('skip', port: managementPort, ok: false,
          error: 'managementPort <= 0');
      return false;
    }
    final startAt = DateTime.now();
    final url = 'http://127.0.0.1:$managementPort/source/status';
    AppLog.instance.http('GET', url, port: managementPort,
        caller: 'verifySourceLoaded');
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 2),
      sendTimeout: const Duration(seconds: 2),
      receiveTimeout: const Duration(seconds: 2),
    ));
    try {
      final resp = await dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      final elapsed = DateTime.now().difference(startAt).inMilliseconds;
      if (resp.statusCode != 200) {
        AppLog.instance.http('GET', url, port: managementPort,
            statusCode: resp.statusCode, elapsedMs: elapsed, ok: false,
            caller: 'verifySourceLoaded');
        AppLog.instance.verify('http_non_200', port: managementPort,
            statusCode: resp.statusCode, elapsedMs: elapsed, ok: false,
            error: 'HTTP ${resp.statusCode}');
        return false;
      }
      final body = resp.data ?? '';
      // main.js /source/status 返回 { sourceLoaded: sourceModule !== null, ... }
      // 必须 sourceLoaded=true 才算 Node.js 源真的已加载
      final loaded = body.contains('"sourceLoaded":true') ||
          body.contains('"sourceLoaded": true');
      AppLog.instance.http('GET', url, port: managementPort,
          statusCode: resp.statusCode, elapsedMs: elapsed, ok: true,
          caller: 'verifySourceLoaded');
      AppLog.instance.verify('parse', port: managementPort,
          statusCode: resp.statusCode, elapsedMs: elapsed,
          ok: loaded, body: body,
          fields: {'sourceLoaded': loaded});
      return loaded;
    } catch (e) {
      final elapsed = DateTime.now().difference(startAt).inMilliseconds;
      AppLog.instance.http('GET', url, port: managementPort,
          elapsedMs: elapsed, ok: false,
          error: e.toString(),
          caller: 'verifySourceLoaded');
      AppLog.instance.verify('exception', port: managementPort,
          elapsedMs: elapsed, ok: false, error: e.toString());
      return false;
    }
  }

  /// 真实 HTTP 探测 mgmtServer 是否健康
  ///
  /// 用于判断 Node.js 进程是否真的活着. iOS 后台过久 embed library
  /// 可能被 SIGKILL, 但 Swift 端 `_isRunning` 状态卡在 true, Dart
  /// 端 onNodeExit callback 不一定及时触发. **不能信 isRunning**,
  /// 必须发真实 HTTP 请求到 mgmtServer 的 /check 端点.
  Future<bool> verifyManagementPort(int port) async {
    if (port <= 0) {
      AppLog.instance.verify('skip', port: port, ok: false,
          error: 'port <= 0');
      return false;
    }
    final startAt = DateTime.now();
    final url = 'http://127.0.0.1:$port/check';
    AppLog.instance.http('GET', url, port: port,
        caller: 'verifyManagementPort');
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 2),
      sendTimeout: const Duration(seconds: 2),
      receiveTimeout: const Duration(seconds: 2),
    ));
    try {
      final resp = await dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      final elapsed = DateTime.now().difference(startAt).inMilliseconds;
      if (resp.statusCode != 200) {
        AppLog.instance.http('GET', url, port: port,
            statusCode: resp.statusCode, elapsedMs: elapsed, ok: false,
            caller: 'verifyManagementPort');
        AppLog.instance.verify('http_non_200', port: port,
            statusCode: resp.statusCode, elapsedMs: elapsed, ok: false,
            error: 'HTTP ${resp.statusCode}');
        return false;
      }
      final body = resp.data ?? '';
      // main.js /check 返回 { run: true, ready: isReady }
      // ready=true 表示 mgmtServer listen 完
      final ready = body.contains('"ready":true') ||
          body.contains('"ready": true');
      AppLog.instance.http('GET', url, port: port,
          statusCode: resp.statusCode, elapsedMs: elapsed, ok: true,
          caller: 'verifyManagementPort');
      AppLog.instance.verify('parse', port: port,
          statusCode: resp.statusCode, elapsedMs: elapsed,
          ok: ready, body: body, fields: {'ready': ready});
      return ready;
    } catch (e) {
      final elapsed = DateTime.now().difference(startAt).inMilliseconds;
      AppLog.instance.http('GET', url, port: port,
          elapsedMs: elapsed, ok: false,
          error: e.toString(),
          caller: 'verifyManagementPort');
      AppLog.instance.verify('exception', port: port,
          elapsedMs: elapsed, ok: false, error: e.toString());
      return false;
    }
  }

  Future<bool> reloadSourceViaManagementPort(int port) async {
    if (port <= 0) {
      AppLog.instance.reload('skip', port: port, ok: false,
          error: 'port <= 0');
      return false;
    }
    final startAt = DateTime.now();
    final url = 'http://127.0.0.1:$port/source/loadPath';
    try {
      final sourcePath = await getDocumentsSourcePath();
      AppLog.instance.reload('start', port: port,
          fields: {'sourcePath': sourcePath, 'url': url});
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        sendTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ));
      final resp = await dio.post(
        url,
        data: {'path': sourcePath},
        options: Options(
          contentType: 'application/json',
          responseType: ResponseType.plain,
        ),
      );
      final elapsed = DateTime.now().difference(startAt).inMilliseconds;
      final ok = resp.statusCode != null && resp.statusCode! < 400;
      AppLog.instance.http('POST', url, port: port,
          statusCode: resp.statusCode, elapsedMs: elapsed, ok: ok,
          caller: 'reloadSourceViaManagementPort');
      AppLog.instance.reload(ok ? 'ok' : 'fail', port: port,
          statusCode: resp.statusCode, elapsedMs: elapsed, ok: ok,
          error: ok ? null : 'HTTP ${resp.statusCode}');
      return ok;
    } catch (e) {
      final elapsed = DateTime.now().difference(startAt).inMilliseconds;
      AppLog.instance.http('POST', url, port: port,
          elapsedMs: elapsed, ok: false,
          error: e.toString(),
          caller: 'reloadSourceViaManagementPort');
      AppLog.instance.reload('exception', port: port,
          elapsedMs: elapsed, ok: false, error: e.toString());
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
    final startAt = DateTime.now();
    AppLog.instance.nodejs('http_server_start');
    try {
      _httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _nativeServerPort = _httpServer!.port;
      AppLog.instance.nodejs('http_server_ok', elapsedMs:
          DateTime.now().difference(startAt).inMilliseconds, fields: {
        'port': _nativeServerPort,
      });
      print('[NodeJSManager] 本地通知服务器已启动，端口: $_nativeServerPort');

      _httpServer!.listen((HttpRequest request) {
        _handleRequest(request);
      });
      return true;
    } catch (e) {
      AppLog.instance.nodejs('http_server_fail',
          elapsedMs: DateTime.now().difference(startAt).inMilliseconds,
          ok: false, error: e.toString());
      print('[NodeJSManager] 本地 Web 服务器启动失败: $e');
      return false;
    }
  }

  void _stopHttpServer() {
    if (_httpServer == null && _nativeServerPort == 0) {
      AppLog.instance.nodejs('http_server_stop_skip',
          fields: {'reason': 'already stopped'});
      return;
    }
    AppLog.instance.nodejs('http_server_stop', fields: {
      'beforePort': _nativeServerPort,
    });
    _httpServer?.close(force: true);
    _httpServer = null;
    _nativeServerPort = 0;
    AppLog.instance.nodejs('http_server_stopped');
  }

  void _handleRequest(HttpRequest request) {
    final path = request.uri.path;
    final query = request.uri.queryParameters;
    final remotePort = request.connectionInfo?.remotePort ?? 0;
    final receivedAt = DateTime.now();

    AppLog.instance.ports('http_request_in', fields: {
      'method': request.method,
      'path': path,
      'query': query.toString(),
      'remotePort': remotePort,
      'remoteAddress': request.connectionInfo?.remoteAddress.address,
    });

    if (path == '/onCatPawOpenPort' && request.method == 'GET') {
      final portStr = query['port'];
      final typeStr = query['type'] ?? 'spider';
      if (portStr != null) {
        final newPort = int.tryParse(portStr) ?? 0;
        final oldSpider = _platform.spiderPort;
        final oldMgmt = _platform.managementPort;
        AppLog.instance.ports('onCatPawOpenPort_in', fields: {
          'newPort': newPort,
          'type': typeStr,
          'oldSpider': oldSpider,
          'oldMgmt': oldMgmt,
        });
        _platform.onPortReceived(newPort, typeStr);
        AppLog.instance.ports('onCatPawOpenPort_done', fields: {
          'newPort': newPort,
          'type': typeStr,
          'afterSpider': _platform.spiderPort,
          'afterMgmt': _platform.managementPort,
          'elapsedMs': DateTime.now().difference(receivedAt).inMilliseconds,
        });
      }
      request.response
        ..write('OK')
        ..close();
    } else if (path == '/onMessage' && request.method == 'POST') {
      final contentLength = request.contentLength;
      AppLog.instance.ports('onMessage_in', fields: {
        'contentLength': contentLength,
      });
      if (contentLength > 0 && contentLength <= 1024 * 1024) {
        final builder = BytesBuilder();
        request.listen(
          (data) => builder.add(data),
          onDone: () {
            try {
              final body = utf8.decode(builder.toBytes());
              final json = jsonDecode(body) as Map<String, dynamic>;
              final message = json['message'] as String?;
              AppLog.instance.ports('onMessage_done', fields: {
                'message': message,
                'elapsedMs': DateTime.now().difference(receivedAt).inMilliseconds,
              });
              if (message != null) {
                _platform.onMessage(message);
              }
            } catch (e) {
              AppLog.instance.ports('onMessage_parse_fail',
                  ok: false, error: e.toString());
              print('[NodeJSManager] 解析消息失败: $e');
            }
            request.response
              ..write('OK')
              ..close();
          },
          onError: (e) {
            AppLog.instance.ports('onMessage_read_fail',
                ok: false, error: e.toString());
            print('[NodeJSManager] 读取消息失败: $e');
            request.response
              ..statusCode = HttpStatus.badRequest
              ..close();
          },
        );
      } else {
        AppLog.instance.ports('onMessage_skip',
            fields: {'reason': 'contentLength=$contentLength 不在范围'});
        request.response
          ..write('OK')
          ..close();
      }
    } else {
      AppLog.instance.ports('http_request_unknown', fields: {
        'method': request.method,
        'path': path,
      });
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
