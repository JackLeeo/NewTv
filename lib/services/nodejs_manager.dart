import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// NodeJS 管理器 - 对应 Swift NodeJSManager
/// 在 Windows 上通过 Process.start() 启动外部 Node.js 进程
/// 运行本地 HTTP 服务器接收 Node.js 的通知
///
/// **打包策略**：
/// - **Node.js 运行时（node.exe）不内嵌到安装包**。首次启动时由
///   [NodeJSManager] 从 [version.json] 指定的镜像下载 zip 包，解压到
///   `getApplicationSupportDirectory()/node-runtime/node.exe`
///   → 极大减小安装包体积（少 ~70 MB）+ 仓库体积
/// - `main.js` 通过 `assets/nodejs-project/dist/main.js` 嵌入，首次启动时
///   复制到 `getApplicationSupportDirectory()/nodejs/main.js`
/// - 用户下载的源（`index.js` + `index.config.js`）保存到
///   `getApplicationDocumentsDirectory()/nodejs/source/`
/// - 安装器（Installer.cs）也支持在安装时下载 Node.js，作为"装完即用"的兜底
class NodeJSManager {
  static final NodeJSManager _instance = NodeJSManager._internal();
  static NodeJSManager get instance => _instance;

  static const int _maxStartupWaitSeconds = 30;

  /// rootBundle 中的 Node.js 元数据
  static const String _bundledNodeVersionMeta =
      'assets/nodejs-runtime/version.json';

  /// rootBundle 中的 main.js
  static const String _bundledMainJs = 'assets/nodejs-project/dist/main.js';

  /// Node.js 下载配置
  NodeDownloadConfig? _nodeDownloadConfig;
  NodeDownloadConfig? get nodeDownloadConfig => _nodeDownloadConfig;

  /// Node.js 下载进度（0.0 ~ 1.0）。UI 可以监听这个 ValueNotifier 显示进度
  /// - null = 还没开始
  /// - 0.0 = 开始
  /// - 1.0 = 完成
  /// - 0.0 再次 = 重新开始（用于多次下载）
  final ValueNotifier<double?> nodeDownloadProgress = ValueNotifier(null);

  /// Node.js 下载状态（用于 UI 弹 dialog）
  /// - null = 空闲
  /// - 'downloading' = 下载中
  /// - 'extracting' = 解压中
  /// - 'done' = 完成
  /// - 'error' = 出错
  final ValueNotifier<String?> nodeDownloadStatus = ValueNotifier(null);

  bool _isRunning = false;
  bool _isNodeReady = false;
  int _nativeServerPort = 0;
  int _managementPort = 0;
  int _spiderPort = 0;

  Process? _nodeProcess;
  HttpServer? _httpServer;

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 15),
  ));

  bool get isRunning => _isRunning;
  bool get isNodeReady => _isNodeReady;
  int get nativeServerPort => _nativeServerPort;
  int get managementPort => _managementPort;
  int get spiderPort => _spiderPort;

  NodeJSManager._internal();

  // ============================================================
  // 运行时目录解析
  // ============================================================

  /// Node.js 运行时目录（自包含 node.exe）
  /// - 路径：`<AppSupport>/node-runtime/`
  Future<String> _getNodeRuntimeDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}node-runtime');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  /// 自包含 node.exe 的目标路径
  Future<String> _getBundledNodeExePath() async {
    final dir = await _getNodeRuntimeDir();
    return '$dir${Platform.pathSeparator}node.exe';
  }

  /// 应用支持目录下的 nodejs 子目录（main.js）
  Future<String> _getNodeJsDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}nodejs');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  /// 本地 main.js 脚本路径（在应用支持目录中）
  Future<String> _getLocalScriptPath() async {
    final dir = await _getNodeJsDir();
    return '$dir${Platform.pathSeparator}main.js';
  }

  /// 应用文档目录下的 nodejs/source/ - 用户下载的源
  Future<String> getDocumentsSourcePath() async {
    final docs = await getApplicationDocumentsDirectory();
    final sourcePath =
        '${docs.path}${Platform.pathSeparator}nodejs${Platform.pathSeparator}source';
    final dir = Directory(sourcePath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return sourcePath;
  }

  // ============================================================
  // 资源准备（main.js / node.exe 缺失则下载）
  // ============================================================

  /// 加载 Node.js 版本元信息（从 rootBundle）
  Future<NodeDownloadConfig> _loadNodeDownloadConfig() async {
    if (_nodeDownloadConfig != null) return _nodeDownloadConfig!;
    final raw = await rootBundle.loadString(_bundledNodeVersionMeta);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final cfg = NodeDownloadConfig.fromJson(json);
    _nodeDownloadConfig = cfg;
    return cfg;
  }

  /// 公开版本，供 UI 层访问下载配置
  Future<NodeDownloadConfig> loadNodeDownloadConfigPublic() async {
    return _loadNodeDownloadConfig();
  }

  /// 确保 Node.js 运行时已就绪
  ///
  /// 流程：
  /// 1. 读 `version.json` 获取下载 URL + zip 内 node.exe 的相对路径
  /// 2. 检查 `<AppSupport>/node-runtime/node.exe` 是否存在且大小合理
  ///    → 存在：直接返回路径（秒开）
  ///    → 不存在：调 [downloadAndExtractNodeRuntime] 下载 + 解压
  ///
  /// 注意：**不要在 UI 主线程直接调**，需要先弹下载进度 dialog。
  /// 推荐调用方：
  /// ```dart
  /// if (await NodeJSManager.instance.isNodeRuntimeInstalled()) {
  ///   // 已装，直接启动
  ///   await NodeJSManager.instance.startNodeJS();
  /// } else {
  ///   // 弹下载 dialog
  ///   final ok = await showDownloadDialog(...);
  ///   if (ok) await NodeJSManager.instance.startNodeJS();
  /// }
  /// ```
  Future<String> _ensureNodeRuntimeReady() async {
    final cfg = await _loadNodeDownloadConfig();
    final exePath = await _getBundledNodeExePath();
    final exeFile = File(exePath);

    if (await exeFile.exists() && (await exeFile.length()) > 1000000) {
      print('[NodeJSManager] node.exe 已存在: $exePath '
          '(${(await exeFile.length()) ~/ 1024} KB)');
      return exePath;
    }

    print('[NodeJSManager] node.exe 不存在，自动下载 Node.js ${cfg.version}...');
    await downloadAndExtractNodeRuntime(cfg);
    return exePath;
  }

  /// 检查 node.exe 是否已安装
  Future<bool> isNodeRuntimeInstalled() async {
    final exePath = await _getBundledNodeExePath();
    final exeFile = File(exePath);
    if (!await exeFile.exists()) return false;
    return (await exeFile.length()) > 1000000;
  }

  /// 下载并解压 Node.js 运行时
  ///
  /// 步骤：
  /// 1. 下载 zip 到内存（流式，实时推 [nodeDownloadProgress]）
  /// 2. 解压 zip
  /// 3. 从中提取 `node.exe` 写到 `<AppSupport>/node-runtime/node.exe`
  ///
  /// UI 可通过监听 [nodeDownloadProgress] + [nodeDownloadStatus] 显示进度 dialog
  /// [cfg] 默认为 [_loadNodeDownloadConfig] 自动加载的版本
  /// [onProgress] 额外的本地回调（除 [nodeDownloadProgress] 外）
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

    // 用进度回调包装的 Dio
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 5),
      responseType: ResponseType.bytes,
    ));

    print('[NodeJSManager] 下载 Node.js zip: ${cfg.downloadUrl}');
    final bytes = <int>[];
    int received = 0;
    int? total;

    try {
      final response = await dio.get<ResponseBody>(
        cfg.downloadUrl,
        options: Options(responseType: ResponseType.stream),
      );
      final body = response.data;
      if (body == null) {
        throw Exception('下载响应体为空');
      }
      final contentLength = body.contentLength;
      if (contentLength != null && contentLength > 0) {
        total = contentLength;
      }
      final stream = body.stream;
      await for (final chunk in stream) {
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

    print('[NodeJSManager] 下载完成: ${bytes.length} 字节，写入临时文件');
    final tmpZip = File(tmpZipPath);
    await tmpZip.writeAsBytes(bytes, flush: true);

    // 解压
    nodeDownloadStatus.value = 'extracting';
    print('[NodeJSManager] 解压 Node.js zip...');
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
          '在 zip 中未找到 ${cfg.exeRelativePathInZip}，'
          'zip 内容: ${archive.files.map((f) => f.name).take(5).join(", ")}...'),
    );

    final runtimeDir = Directory(await _getNodeRuntimeDir());
    if (!await runtimeDir.exists()) {
      await runtimeDir.create(recursive: true);
    }
    final destExe = File(await _getBundledNodeExePath());
    await destExe.writeAsBytes(exeFile.content as List<int>, flush: true);
    print(
        '[NodeJSManager] node.exe 已就绪: ${destExe.path} (${exeFile.size} 字节)');

    // 删除临时 zip
    try {
      await tmpZip.delete();
    } catch (_) {}

    nodeDownloadStatus.value = 'done';
    // 2 秒后清空状态（让 UI 来得及显示完成状态）
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
    // 检查本地文件是否已经存在且非空
    if (await localFile.exists() && (await localFile.length()) > 0) {
      return localPath;
    }
    try {
      print('[NodeJSManager] 从 rootBundle 解压 main.js...');
      final data = await rootBundle.load(_bundledMainJs);
      final bytes = data.buffer.asUint8List();
      await localFile.writeAsBytes(bytes, flush: true);
      print('[NodeJSManager] main.js 已就绪: $localPath (${bytes.length} 字节)');
      return localPath;
    } catch (e) {
      print('[NodeJSManager] 解压 main.js 失败: $e');
      return '';
    }
  }

  /// 计算数据的 MD5 哈希
  String _md5Hex(Uint8List data) {
    return md5.convert(data).toString();
  }

  // ============================================================
  // 本地 HTTP 服务器（接收 Node.js 通知）
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

  /// 处理来自 Node.js 的 HTTP 请求
  void _handleRequest(HttpRequest request) {
    final path = request.uri.path;
    final query = request.uri.queryParameters;

    if (path == '/onCatPawOpenPort' && request.method == 'GET') {
      final portStr = query['port'];
      final typeStr = query['type'] ?? 'spider';
      if (portStr != null) {
        final port = int.tryParse(portStr) ?? 0;
        print('[NodeJSManager] 收到端口通知: $port, 类型: $typeStr');

        if (typeStr == 'management') {
          _managementPort = port;
        } else {
          _spiderPort = port;
        }
      }
      request.response
        ..write('OK')
        ..close();
    } else if (path == '/onMessage' && request.method == 'POST') {
      final contentLength = request.contentLength;
      if (contentLength > 0 && contentLength <= 1024 * 1024) {
        final builder = BytesBuilder();
        request.listen(
          (data) {
            builder.add(data);
          },
          onDone: () {
            try {
              final body = utf8.decode(builder.toBytes());
              final json = jsonDecode(body) as Map<String, dynamic>;
              final message = json['message'] as String?;
              if (message != null) {
                print('[NodeJSManager] 收到 Node.js 消息: $message');
                if (message == 'ready') {
                  _isNodeReady = true;
                }
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

  // ============================================================
  // 启动 / 停止 Node.js
  // ============================================================

  /// 启动 Node.js 进程
  Future<bool> startNodeJS() async {
    if (_isRunning) return true;

    _isNodeReady = false;
    _spiderPort = 0;
    _managementPort = 0;

    // 1) 从 rootBundle 解压 node.exe + main.js
    final String nodeExePath;
    try {
      nodeExePath = await _ensureNodeRuntimeReady();
    } catch (e) {
      print('[NodeJSManager] Node.js 运行时准备失败: $e');
      return false;
    }
    final nodeExe = File(nodeExePath);
    if (!await nodeExe.exists()) {
      print('[NodeJSManager] Node.js 可执行文件不存在: $nodeExePath');
      return false;
    }

    final scriptPath = await _ensureScriptReady();
    if (scriptPath.isEmpty) {
      print('[NodeJSManager] 无法准备 Node.js 脚本');
      return false;
    }

    // 2) 启动本地 HTTP 服务器
    if (!await _startLocalWebServer()) {
      return false;
    }

    print('[NodeJSManager] 启动 Node.js，node: $nodeExePath, script: $scriptPath, nativeServerPort: $_nativeServerPort');

    // 3) NODE_PATH 指向用户下载的源目录
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
        environment: {
          'NODE_PATH': sourcePath,
        },
        workingDirectory: File(scriptPath).parent.path,
      );

      _isRunning = true;

      // 监听 stdout
      _nodeProcess!.stdout.listen(
        (data) {
          final output = utf8.decode(data, allowMalformed: true).trim();
          if (output.isNotEmpty) {
            print('[NodeJS stdout] $output');
          }
        },
      );

      // 监听 stderr
      _nodeProcess!.stderr.listen(
        (data) {
          final output = utf8.decode(data, allowMalformed: true).trim();
          if (output.isNotEmpty) {
            print('[NodeJS stderr] $output');
          }
        },
      );

      // 监听进程退出
      _nodeProcess!.exitCode.then((exitCode) {
        print('[NodeJSManager] Node.js 进程退出，退出码: $exitCode');
        _isRunning = false;
        _isNodeReady = false;
        _stopHttpServer();
      });

      // 等待 Node.js 就绪
      return await waitForNodeReady();
    } catch (e) {
      print('[NodeJSManager] 启动 Node.js 失败: $e');
      _isRunning = false;
      return false;
    }
  }

  /// 停止 Node.js 进程
  void stopNodeJS() {
    if (!_isRunning) return;

    _isRunning = false;
    _isNodeReady = false;
    _stopHttpServer();
    _nativeServerPort = 0;
    _spiderPort = 0;
    _managementPort = 0;

    _nodeProcess?.kill();
    _nodeProcess = null;

    print('[NodeJSManager] Node.js 已停止');
  }

  /// 强制重置运行状态
  void forceResetRunningState() {
    _isRunning = false;
    _isNodeReady = false;
    _stopHttpServer();
    _nativeServerPort = 0;
    _spiderPort = 0;
    _managementPort = 0;

    _nodeProcess?.kill();
    _nodeProcess = null;

    print('[NodeJSManager] 强制重置运行状态');
  }

  void _stopHttpServer() {
    _httpServer?.close(force: true);
    _httpServer = null;
  }

  // ============================================================
  // 等待就绪
  // ============================================================

  /// 等待 Node.js 就绪
  Future<bool> waitForNodeReady() async {
    if (_isNodeReady) return true;

    final deadline = DateTime.now().add(
      Duration(seconds: _maxStartupWaitSeconds),
    );

    while (DateTime.now().isBefore(deadline)) {
      if (_isNodeReady) return true;
      await Future.delayed(const Duration(milliseconds: 200));
    }

    print('[NodeJSManager] 等待 Node.js 就绪超时');
    return _isNodeReady;
  }

  /// 等待 Spider 端口就绪
  Future<bool> waitForSpiderPort() async {
    if (_spiderPort > 0) return true;

    final deadline = DateTime.now().add(
      const Duration(seconds: 30),
    );

    while (DateTime.now().isBefore(deadline)) {
      if (_spiderPort > 0) return true;
      await Future.delayed(const Duration(milliseconds: 200));
    }

    print('[NodeJSManager] 等待 Spider 端口超时');
    return _spiderPort > 0;
  }

  // ============================================================
  // 源管理
  // ============================================================

  /// 从 URL 加载源文件
  /// 1. 下载 JS 文件和 MD5 校验文件
  /// 2. 验证 MD5
  /// 3. 保存到本地
  /// 4. 通过 management 端口加载
  Future<(bool success, String? message)> loadSource(
      String urlString) async {
    if (urlString.isEmpty) {
      return (false, 'URL 为空');
    }

    // 规范化 URL（移除 .md5 后缀）
    var normalizedUrl = urlString;
    if (normalizedUrl.endsWith('.js.md5')) {
      normalizedUrl =
          normalizedUrl.substring(0, normalizedUrl.length - 4);
      print('[NodeJSManager] 规范化 URL（移除 .md5 后缀）: $normalizedUrl');
    }

    final uri = Uri.tryParse(normalizedUrl);
    if (uri == null) {
      return (false, '无效的 URL');
    }

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
        '[NodeJSManager] 缓存检查: index.js 存在=$localJSExists, index.js.md5 存在=$localMd5Exists');

    // 如果本地有缓存，先检查 MD5 是否匹配
    if (localJSExists && localMd5Exists) {
      try {
        final md5Url = '$normalizedUrl.md5';
        print('[NodeJSManager] 缓存检查: 下载远程 MD5: $md5Url');

        String? remoteMd5;
        try {
          final response = await _dio.get<String>(
            md5Url,
            options: Options(responseType: ResponseType.plain),
          );
          if (response.statusCode == 200 && response.data != null) {
            remoteMd5 = response.data!.trim();
            print('[NodeJSManager] 远程 MD5 已下载，内容: $remoteMd5');
          }
        } on DioException catch (e) {
          print('[NodeJSManager] 远程 MD5 下载失败: ${e.message}');
        }

        if (remoteMd5 != null && remoteMd5.isNotEmpty) {
          final localMd5Content =
              await File(indexMd5Path).readAsString();
          final localMd5 = localMd5Content.trim();

          print(
              '[NodeJSManager] 缓存 MD5 比较: 本地=$localMd5, 远程=$remoteMd5');

          if (localMd5 == remoteMd5) {
            print(
                '[NodeJSManager] MD5 匹配！使用缓存源，跳过下载');
            return await _sendLoadCommandToNodeJS(sourcePath);
          } else {
            print(
                '[NodeJSManager] MD5 不匹配，需要重新下载源');
          }
        } else {
          print(
              '[NodeJSManager] 无法下载远程 MD5，继续完整下载');
        }
      } catch (e) {
        print('[NodeJSManager] MD5 缓存检查异常: $e');
      }
    }

    // 下载主源文件
    Uint8List? jsData;
    String? md5Data;
    Uint8List? configData;
    String? configMd5Data;

    try {
      print('[NodeJSManager] 下载主源文件: $normalizedUrl');
      final jsResponse = await _dio.get<List<int>>(
        normalizedUrl,
        options: Options(responseType: ResponseType.bytes),
      );
      if (jsResponse.statusCode == 200 && jsResponse.data != null) {
        jsData = Uint8List.fromList(jsResponse.data!);
        print(
            '[NodeJSManager] 主源文件已下载，大小: ${jsData.length} 字节');
      } else {
        return (
          false,
          '下载源文件失败 (状态码: ${jsResponse.statusCode})'
        );
      }
    } on DioException catch (e) {
      return (false, '下载源文件失败: ${e.message}');
    }

    // 下载 MD5 文件
    try {
      final md5Url = '$normalizedUrl.md5';
      print('[NodeJSManager] 下载 MD5: $md5Url');
      final md5Response = await _dio.get<String>(
        md5Url,
        options: Options(responseType: ResponseType.plain),
      );
      if (md5Response.statusCode == 200 && md5Response.data != null) {
        md5Data = md5Response.data!.trim();
        print('[NodeJSManager] MD5 已下载');
      }
    } on DioException catch (e) {
      print('[NodeJSManager] MD5 下载失败（可选）: ${e.message}');
    }

    // 下载 config 文件
    try {
      final configUrl =
          normalizedUrl.replaceAll('/index.js', '/index.config.js');
      print('[NodeJSManager] 下载配置: $configUrl');
      final configResponse = await _dio.get<List<int>>(
        configUrl,
        options: Options(responseType: ResponseType.bytes),
      );
      if (configResponse.statusCode == 200 &&
          configResponse.data != null) {
        configData = Uint8List.fromList(configResponse.data!);
        print('[NodeJSManager] 配置已下载');
      }
    } on DioException catch (e) {
      print('[NodeJSManager] 配置下载失败（可选）: ${e.message}');
    }

    // 下载 config MD5
    if (configData != null) {
      try {
        final configUrl =
            normalizedUrl.replaceAll('/index.js', '/index.config.js');
        final configMd5Url = '$configUrl.md5';
        final configMd5Response = await _dio.get<String>(
          configMd5Url,
          options: Options(responseType: ResponseType.plain),
        );
        if (configMd5Response.statusCode == 200 &&
            configMd5Response.data != null) {
          configMd5Data = configMd5Response.data!.trim();
        }
      } on DioException catch (_) {}
    }

    // 验证 MD5
    if (md5Data != null && md5Data.isNotEmpty) {
      final actualMd5 = _md5Hex(jsData!);
      if (actualMd5 != md5Data) {
        print(
            '[NodeJSManager] MD5 校验失败: 期望=$md5Data, 实际=$actualMd5');
        return (false, 'MD5 校验失败');
      }
      print('[NodeJSManager] 下载的源文件 MD5 校验通过');
    }

    // 保存文件
    final sourceDir = Directory(sourcePath);
    if (!await sourceDir.exists()) {
      await sourceDir.create(recursive: true);
    }

    print('[NodeJSManager] 写入 index.js 到: $indexJSPath');
    await File(indexJSPath).writeAsBytes(jsData!);

    if (md5Data != null) {
      await File(indexMd5Path).writeAsString(md5Data);
      print('[NodeJSManager] 已保存 index.js.md5 用于缓存检查');
    }

    if (configData != null) {
      print('[NodeJSManager] 写入 index.config.js');
      await File(configJSPath).writeAsBytes(configData);
      if (configMd5Data != null) {
        await File(configMd5Path).writeAsString(configMd5Data);
      }
    } else {
      print('[NodeJSManager] 创建默认 index.config.js');
      await File(configJSPath)
          .writeAsString('module.exports = { color: [] };');
    }

    print(
        '[NodeJSManager] 文件保存成功，现在发送加载命令到 Node.js，路径: $sourcePath');
    return await _sendLoadCommandToNodeJS(sourcePath);
  }

  /// 发送加载命令到 Node.js（带重试）
  Future<(bool success, String? message)> _sendLoadCommandToNodeJS(
    String path, {
    int retryCount = 3,
  }) async {
    print(
        '[NodeJSManager] _sendLoadCommandToNodeJS 被调用，managementPort: $_managementPort, 重试次数: $retryCount');

    if (_managementPort <= 0) {
      if (retryCount > 0) {
        print(
            '[NodeJSManager] Management 端口未就绪，重试中...（剩余 $retryCount 次）');
        await Future.delayed(const Duration(seconds: 2));
        return _sendLoadCommandToNodeJS(path, retryCount: retryCount - 1);
      }
      const errorMsg = 'Management 服务器重试后仍未就绪';
      print('[NodeJSManager] 错误: $errorMsg');
      return (false, errorMsg);
    }

    final urlString = 'http://127.0.0.1:$_managementPort/source/loadPath';
    print('[NodeJSManager] 发送请求到: $urlString');

    try {
      final response = await _dio.post<dynamic>(
        urlString,
        data: jsonEncode({'path': path}),
        options: Options(
          contentType: 'application/json',
          responseType: ResponseType.json,
        ),
      );

      final statusCode = response.statusCode ?? 0;
      final responseBody = response.data?.toString() ?? '';
      print(
          '[NodeJSManager] 响应状态码: $statusCode, 内容: $responseBody');

      if (statusCode >= 400) {
        if (statusCode >= 500 && retryCount > 0) {
          print(
              '[NodeJSManager] 服务器错误，重试中...（剩余 $retryCount 次）');
          return _sendLoadCommandToNodeJS(path,
              retryCount: retryCount - 1);
        }
        return (false, '服务器错误 ($statusCode): $responseBody');
      }

      final data = response.data;
      if (data is Map<String, dynamic>) {
        if (data.containsKey('error') && data['error'] != null) {
          final errorMsg = '加载错误: ${data['error']}';
          print('[NodeJSManager] 错误: $errorMsg');
          return (false, errorMsg);
        }
      }

      print('[NodeJSManager] === 源加载成功！ ===');
      return (true, '源加载成功');
    } on DioException catch (e) {
      print('[NodeJSManager] 加载命令失败: ${e.message}');
      if (retryCount > 0) {
        print('[NodeJSManager] 重试中...（剩余 $retryCount 次）');
        return _sendLoadCommandToNodeJS(path,
            retryCount: retryCount - 1);
      }
      return (false, e.message ?? '请求失败');
    }
  }

  /// 删除本地源文件
  Future<bool> deleteSource() async {
    final sourcePath = await getDocumentsSourcePath();
    final dir = Directory(sourcePath);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    _spiderPort = 0;
    return true;
  }

  // ============================================================
  // 端口检查
  // ============================================================

  /// 检查本地端口是否可达
  Future<bool> checkLocalPort(int port) async {
    try {
      final url = 'http://127.0.0.1:$port/';
      final response = await _dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );
      return response.statusCode != null &&
          response.statusCode! >= 200 &&
          response.statusCode! < 500;
    } on DioException catch (_) {
      return false;
    }
  }

  /// 通过 management 端口重新加载源
  Future<bool> reloadSourceViaManagementPort(int port) async {
    final sourcePath = await getDocumentsSourcePath();
    if (sourcePath.isEmpty) return false;

    final urlString = 'http://127.0.0.1:$port/source/loadPath';

    try {
      final response = await _dio.post<dynamic>(
        urlString,
        data: jsonEncode({'path': sourcePath}),
        options: Options(
          contentType: 'application/json',
          responseType: ResponseType.json,
        ),
      );

      if (response.statusCode != null &&
          response.statusCode! >= 200 &&
          response.statusCode! <= 299) {
        await Future.delayed(const Duration(seconds: 2));

        if (_spiderPort > 0) {
          if (await checkLocalPort(_spiderPort)) {
            return true;
          }
        }

        final portReady = await waitForSpiderPort();
        return portReady;
      }
    } on DioException catch (_) {}

    return false;
  }
}

/// Node.js 下载配置
///
/// 对应 [assets/nodejs-runtime/version.json] 的 schema
class NodeDownloadConfig {
  final String version;
  final String mirror;
  final String downloadUrl;
  final String exeRelativePathInZip;
  final int zipSizeHintMb;
  final String minAppVersion;

  NodeDownloadConfig({
    required this.version,
    required this.mirror,
    required this.downloadUrl,
    required this.exeRelativePathInZip,
    required this.zipSizeHintMb,
    required this.minAppVersion,
  });

  factory NodeDownloadConfig.fromJson(Map<String, dynamic> json) {
    return NodeDownloadConfig(
      version: (json['version'] as String?) ?? '20.11.1',
      mirror:
          (json['mirror'] as String?) ?? 'https://npmmirror.com/mirrors/node',
      downloadUrl: json['download_url'] as String? ??
          'https://npmmirror.com/mirrors/node/v20.11.1/node-v20.11.1-win-x64.zip',
      exeRelativePathInZip: json['exe_relative_path_in_zip'] as String? ??
          'node-v20.11.1-win-x64/node.exe',
      zipSizeHintMb: (json['zip_size_hint_mb'] as num?)?.toInt() ?? 28,
      minAppVersion: (json['min_app_version'] as String?) ?? '1.0.0',
    );
  }

  @override
  String toString() =>
      'NodeDownloadConfig(version=$version, downloadUrl=$downloadUrl)';
}
