// lib/services/app_log.dart
//
// Dart 端应用日志 — 写到 <Documents>/nodejs-project/runtime/app.log
// -----------------------------------------------------------------------------
// **为什么需要文件日志**：
// - iOS release 模式下 print() 走 OSLog，连接 Console 才能看，但用户通常没 Mac
// - 用户可以通过 iPhone Files app → "文件" (On My iPhone) → TVBox
//   → nodejs-project/runtime/app.log 直接拿到日志
// - 后台/锁屏切回等关键事件必须有持久化记录才能定位 bug
//
// **目录约定**（与 Node.js 端约定一致）：
//   <Documents>/nodejs-project/
//     src/source/        # 用户 Spider 源
//     runtime/
//       app.log          # 本服务 (Dart 端)
//       node.log         # Node.js 端 (main.js 写)
//
// **设计**：
// - 单例 AppLog.instance
// - log() 异步追加写, 失败静默不 crash app
// - 同时 print() 让 OSLog 也有记录
// - 不轮转, 不限制大小 (用户自己看)

import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class AppLog {
  static final AppLog _instance = AppLog._internal();
  static AppLog get instance => _instance;
  AppLog._internal();

  File? _logFile;
  String _logPath = '';
  bool _initialized = false;
  final _writeQueue = <String>[]; // 初始化前的日志先缓存
  bool _flushing = false;

  String get logPath => _logPath;
  bool get isInitialized => _initialized;

  /// 初始化: 创建目录和文件
  ///
  /// **必须**在 main() 中 WidgetsFlutterBinding.ensureInitialized() 之后
  /// runApp 之前调用, 否则后续 handleSceneActive 等关键路径写不进文件
  Future<void> init() async {
    if (_initialized) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final runtimeDir =
          Directory('${docs.path}/nodejs-project/runtime');
      if (!await runtimeDir.exists()) {
        await runtimeDir.create(recursive: true);
      }
      _logFile = File('${runtimeDir.path}/app.log');
      _logPath = _logFile!.path;
      _initialized = true;
      // 写启动标记
      await _appendSync(
          '=== AppLog 初始化 (Flutter ${_getFlutterInfo()}) ===');
      // flush 初始化前的缓存
      await _flushQueue();
    } catch (e) {
      // 初始化失败也不能 crash app
      _initialized = true; // 标记为已初始化避免重复尝试
      print('[AppLog] init 失败: $e');
    }
  }

  /// 写日志 (异步追加)
  ///
  /// - 同时 print 让 OSLog 也有记录
  /// - 文件追加失败静默
  /// - init 之前调用会缓存, init 后 flush
  Future<void> log(String message) async {
    final line = '[${DateTime.now().toIso8601String()}] $message';
    // 同步 print, 保证 OSLog 一定看到
    // ignore: avoid_print
    print(line);
    if (!_initialized) {
      _writeQueue.add(line);
      return;
    }
    await _append(line);
  }

  /// 同步追加 (仅 init 内部用, 保证启动标记一定写进去)
  Future<void> _appendSync(String line) async {
    try {
      await _logFile?.writeAsString('$line\n',
          mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  Future<void> _append(String line) async {
    try {
      await _logFile?.writeAsString('$line\n',
          mode: FileMode.append, flush: false);
    } catch (e) {
      // 写文件失败不能 crash app, print 已经有记录
    }
  }

  Future<void> _flushQueue() async {
    if (_flushing) return;
    _flushing = true;
    try {
      while (_writeQueue.isNotEmpty) {
        final line = _writeQueue.removeAt(0);
        await _append(line);
      }
    } finally {
      _flushing = false;
    }
  }

  String _getFlutterInfo() {
    try {
      return 'Dart ${_dartVersion()}';
    } catch (_) {
      return 'unknown';
    }
  }

  String _dartVersion() {
    // ignore: deprecated_member_use
    return Platform.version;
  }

  /// 读取最近 N 行 (给 UI 调试用)
  Future<String> readRecentLines({int lines = 100}) async {
    if (!_initialized || _logFile == null) return '';
    try {
      final content = await _logFile!.readAsString();
      final all = content.split('\n');
      if (all.length <= lines) return content;
      return all.sublist(all.length - lines - 1, all.length - 1).join('\n');
    } catch (_) {
      return '';
    }
  }
}
