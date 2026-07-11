// lib/services/app_log.dart
//
// Dart 端应用日志 — 双写 <Documents>/nodejs-project/runtime/
// -----------------------------------------------------------------------------
// **为什么需要文件日志**：
// - iOS release 模式下 print() 走 OSLog，连接 Console 才能看，但用户通常没 Mac
// - 用户可以通过 iPhone Files app → "文件" (On My iPhone) → TVBox
//   → nodejs-project/runtime/ 拿到日志
//
// **目录约定**（与 Node.js 端约定一致）：
//   <Documents>/nodejs-project/runtime/
//     app.log     # 人类可读, 带 [LEVEL] [CATEGORY:ACTION] 标签 + key=val
//     app.jsonl   # 机器可解析, 每行一个 JSON (jq/Excel/脚本分析)
//     node.log    # Node.js 端 (main.js 写)
//
// **设计**：
// - 单例 AppLog.instance
// - 结构化日志: LogEntry { ts, level, category, action, elapsedMs, message, error, fields }
// - 双写: human 格式写 app.log, JSON 格式写 app.jsonl
// - 串行化 Future chain 保证 UTF-8 不截断, 顺序不乱
// - 便捷方法: lifecycle / scene / verify / reload / ports / http / nodejs / dio
// - 兼容旧 API: log(message) 仍可用 (走 LEGACY category)
//
// **2026-07-09 临时关闭**: 调试期已结束, 文件日志会占用 Documents 缓存空间.
// 暂时停用, 代码保留, 需时把下方 [kLogEnabled] 改成 true 即可恢复.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

/// 日志级别
enum LogLevel { debug, info, warn, error }

extension LogLevelExt on LogLevel {
  String get name {
    switch (this) {
      case LogLevel.debug:
        return 'DEBUG';
      case LogLevel.info:
        return 'INFO';
      case LogLevel.warn:
        return 'WARN';
      case LogLevel.error:
        return 'ERROR';
    }
  }
}

/// 结构化日志条目
class LogEntry {
  final DateTime ts;
  final LogLevel level;
  final String category; // LIFECYCLE, SCENE, VERIFY, RELOAD, RESTART, RETRY, HTTP, PORTS, NODEJS, DIO, LEGACY
  final String action; // start, end, ok, fail, skip, read, write, change
  final Map<String, Object?> fields; // 任意 key=val
  final String? message; // 人类可读描述
  final int? elapsedMs; // 关键操作耗时
  final String? error; // 错误信息
  final String? correlationId; // 关联 id (如 handleSceneActive 单次跑用一个 id)

  LogEntry({
    required this.category,
    required this.action,
    this.level = LogLevel.info,
    Map<String, Object?>? fields,
    this.message,
    this.elapsedMs,
    this.error,
    this.correlationId,
  })  : ts = DateTime.now(),
        fields = fields ?? <String, Object?>{};

  /// 人类可读: [ts.ISO] [LEVEL] [CATEGORY:ACTION] (ms) message key=val key=val ERR=error
  String formatHuman() {
    final buf = StringBuffer();
    buf.write('[${ts.toIso8601String()}]');
    buf.write(' [${level.name}]');
    buf.write(' [$category:$action]');
    if (correlationId != null) buf.write(' cid=$correlationId');
    if (elapsedMs != null) buf.write(' ${elapsedMs}ms');
    if (message != null && message!.isNotEmpty) {
      buf.write(' $message');
    }
    if (fields.isNotEmpty) {
      fields.forEach((k, v) {
        if (v == null) return;
        buf.write(' $k=$v');
      });
    }
    if (error != null && error!.isNotEmpty) {
      buf.write(' ERR=$error');
    }
    return buf.toString();
  }

  /// JSON Line
  String formatJson() {
    final obj = <String, Object?>{
      'ts': ts.toIso8601String(),
      'level': level.name,
      'category': category,
      'action': action,
      if (correlationId != null) 'cid': correlationId,
      if (elapsedMs != null) 'elapsedMs': elapsedMs,
      if (message != null && message!.isNotEmpty) 'msg': message,
      if (error != null && error!.isNotEmpty) 'error': error,
      'fields': fields,
    };
    return jsonEncode(obj);
  }

  @override
  String toString() => formatHuman();
}

class AppLog {
  static final AppLog _instance = AppLog._internal();
  static AppLog get instance => _instance;
  AppLog._internal();

  /// **总开关** - 临时关闭所有日志写入
  ///
  /// false: 关闭所有日志 (不写文件, 不 print, 不创建目录)
  /// true:  恢复日志 (写 <Documents>/nodejs-project/runtime/app.{log,jsonl})
  ///
  /// 调试问题时改成 true, 重新构建, 看 log 即可. 默认 false 是因为调试期已
  /// 结束, 长期写文件会占用 Documents 缓存 (Files app 用户可见).
  static const bool kLogEnabled = false;

  File? _logFile; // app.log
  File? _jsonlFile; // app.jsonl
  String _logPath = '';
  String _jsonlPath = '';
  bool _initialized = false;

  /// 写文件串行化: 所有写操作挂到 chain 末尾, 保证 UTF-8 不截断 + 顺序不乱
  Future<void> _writeChain = Future<void>.value();

  /// 写文件大小限制: 单文件 > 2MB 滚动到 .1 后缀, 保留最近 2 个文件
  static const int _maxFileBytes = 2 * 1024 * 1024;

  String get logPath => _logPath;
  String get jsonlPath => _jsonlPath;
  bool get isInitialized => _initialized;

  /// 初始化: 创建目录和文件
  Future<void> init() async {
    if (_initialized) return;
    // 关闭时连目录都不创建, 节省 IO
    if (!kLogEnabled) {
      _initialized = true;
      return;
    }
    try {
      final docs = await getApplicationDocumentsDirectory();
      final runtimeDir = Directory('${docs.path}/nodejs-project/runtime');
      if (!await runtimeDir.exists()) {
        await runtimeDir.create(recursive: true);
      }
      _logFile = File('${runtimeDir.path}/app.log');
      _logPath = _logFile!.path;
      _jsonlFile = File('${runtimeDir.path}/app.jsonl');
      _jsonlPath = _jsonlFile!.path;
      _initialized = true;

      // 启动标记
      final entry = LogEntry(
        category: 'LOG',
        action: 'init',
        message: 'AppLog initialized (${_getFlutterInfo()})',
        fields: {
          'logPath': _logPath,
          'jsonlPath': _jsonlPath,
        },
      );
      await _appendSync(entry);
    } catch (e) {
      _initialized = true;
      // ignore: avoid_print
      print('[AppLog] init 失败: $e');
    }
  }

  /// 写一条结构化日志 (核心入口, 所有便捷方法最终走这里)
  void entry(LogEntry e) {
    // 总开关 - 关闭时所有 entry 静默丢弃
    if (!kLogEnabled) return;
    final human = e.formatHuman();
    final json = e.formatJson();
    // 同步 print, OSLog 一定能看
    // ignore: avoid_print
    print(human);
    if (!_initialized) return;
    _writeBoth(human, json);
  }

  /// 兼容旧 API: 直接写消息 (LEGACY category, 给旧 log() 调用用)
  void log(String message) {
    entry(LogEntry(
      category: 'LEGACY',
      action: 'msg',
      level: LogLevel.info,
      message: message,
    ));
  }

  // ============================================================
  // 便捷方法 — 按 category 分
  // ============================================================

  /// 记录 lifecycle 转换 (resumed/inactive/hidden/paused)
  void lifecycle(
    String action, {
    AppLifecycleState? from,
    AppLifecycleState? to,
    String? source,
    String? correlationId,
    Map<String, Object?> fields = const {},
  }) {
    final mergedFields = <String, Object?>{
      if (from != null) 'from': from.name,
      if (to != null) 'to': to.name,
      if (source != null) 'source': source,
      ...fields,
    };
    entry(LogEntry(
      category: 'LIFECYCLE',
      action: action,
      level: LogLevel.info,
      fields: mergedFields,
      correlationId: correlationId,
    ));
  }

  /// 记录 handleSceneActive 关键节点
  ///
  /// 用 [sceneStart] 记录开始, [sceneStep] 记录中间步骤, [sceneEnd] 记录结束
  /// correlationId 用于串联同一次 handleSceneActive 跑的所有日志
  String sceneStart(String action, {Map<String, Object?> fields = const {}}) {
    final cid = _newCorrelationId();
    entry(LogEntry(
      category: 'SCENE',
      action: action,
      level: LogLevel.info,
      fields: fields,
      correlationId: cid,
      message: 'handleSceneActive 开始',
    ));
    return cid;
  }

  void sceneStep(
    String correlationId,
    String step, {
    LogLevel level = LogLevel.info,
    int? elapsedMs,
    Map<String, Object?> fields = const {},
    String? message,
    String? error,
  }) {
    entry(LogEntry(
      category: 'SCENE',
      action: step,
      level: level,
      elapsedMs: elapsedMs,
      fields: fields,
      message: message,
      error: error,
      correlationId: correlationId,
    ));
  }

  void sceneEnd(
    String correlationId,
    String outcome, {
    int? elapsedMs,
    bool? ok,
    Map<String, Object?> fields = const {},
    String? error,
  }) {
    entry(LogEntry(
      category: 'SCENE',
      action: 'end',
      level: ok == false ? LogLevel.error : LogLevel.info,
      elapsedMs: elapsedMs,
      fields: {
        'outcome': outcome,
        if (fields.isNotEmpty) ...fields,
      },
      error: error,
      correlationId: correlationId,
      message: 'handleSceneActive 结束 (outcome=$outcome)',
    ));
  }

  /// 记录 verify 操作
  void verify(
    String action, {
    int? port,
    int? statusCode,
    int? elapsedMs,
    bool? ok,
    String? body,
    String? error,
    Map<String, Object?> fields = const {},
  }) {
    final merged = <String, Object?>{
      if (port != null) 'port': port,
      if (statusCode != null) 'statusCode': statusCode,
      if (elapsedMs != null) 'ms': elapsedMs,
      if (ok != null) 'ok': ok,
      if (body != null && body.isNotEmpty && body.length < 200) 'body': body,
      ...fields,
    };
    entry(LogEntry(
      category: 'VERIFY',
      action: action,
      level: ok == false ? LogLevel.warn : LogLevel.info,
      fields: merged,
      error: error,
    ));
  }

  /// 记录 reload 源操作
  void reload(
    String action, {
    int? port,
    int? statusCode,
    int? elapsedMs,
    bool? ok,
    String? error,
    Map<String, Object?> fields = const {},
  }) {
    final merged = <String, Object?>{
      if (port != null) 'port': port,
      if (statusCode != null) 'statusCode': statusCode,
      if (elapsedMs != null) 'ms': elapsedMs,
      if (ok != null) 'ok': ok,
      ...fields,
    };
    entry(LogEntry(
      category: 'RELOAD',
      action: action,
      level: ok == false ? LogLevel.warn : LogLevel.info,
      fields: merged,
      error: error,
    ));
  }

  /// 记录 ports.json 读写 / Node.js 端口变化
  void ports(
    String action, {
    int? pid,
    int? mgmtPort,
    int? spiderPort,
    int? oldMgmtPort,
    int? oldSpiderPort,
    int? oldPid,
    String? path,
    bool? ok,
    String? error,
    Map<String, Object?> fields = const {},
  }) {
    final merged = <String, Object?>{
      if (oldPid != null) 'oldPid': oldPid,
      if (pid != null) 'pid': pid,
      if (oldMgmtPort != null) 'oldMgmt': oldMgmtPort,
      if (mgmtPort != null) 'mgmt': mgmtPort,
      if (oldSpiderPort != null) 'oldSpider': oldSpiderPort,
      if (spiderPort != null) 'spider': spiderPort,
      if (path != null) 'path': path,
      if (ok != null) 'ok': ok,
      ...fields,
    };
    entry(LogEntry(
      category: 'PORTS',
      action: action,
      level: ok == false ? LogLevel.warn : LogLevel.info,
      fields: merged,
      error: error,
    ));
  }

  /// 记录通用 HTTP 请求 (dio 内部用)
  void http(
    String method,
    String url, {
    int? statusCode,
    int? elapsedMs,
    int? port,
    bool? ok,
    String? error,
    String? caller,
  }) {
    final fields = <String, Object?>{
      'method': method,
      'url': url,
      if (port != null) 'port': port,
      if (statusCode != null) 'statusCode': statusCode,
      if (elapsedMs != null) 'ms': elapsedMs,
      if (ok != null) 'ok': ok,
      if (caller != null) 'caller': caller,
    };
    entry(LogEntry(
      category: 'HTTP',
      action: ok == false ? 'fail' : (statusCode != null ? 'ok' : 'start'),
      level: ok == false ? LogLevel.warn : LogLevel.info,
      fields: fields,
      error: error,
    ));
  }

  /// 记录 Node.js 进程操作 (start / stop / exit)
  void nodejs(
    String action, {
    int? pid,
    int? elapsedMs,
    bool? ok,
    String? error,
    Map<String, Object?> fields = const {},
  }) {
    final merged = <String, Object?>{
      if (pid != null) 'pid': pid,
      if (elapsedMs != null) 'ms': elapsedMs,
      if (ok != null) 'ok': ok,
      ...fields,
    };
    entry(LogEntry(
      category: 'NODEJS',
      action: action,
      level: ok == false ? LogLevel.error : LogLevel.info,
      fields: merged,
      error: error,
    ));
  }

  /// 强制 flush
  Future<void> flush() async {
    try {
      await _writeChain;
    } catch (_) {}
  }

  /// 读取 app.log 最近 N 行
  Future<String> readRecentLines({int lines = 100}) async {
    if (!_initialized || _logFile == null) return '';
    try {
      await _writeChain;
      final content = await _logFile!.readAsString();
      final all = content.split('\n');
      if (all.length <= lines) return content;
      return all.sublist(all.length - lines - 1, all.length - 1).join('\n');
    } catch (_) {
      return '';
    }
  }

  /// 读取 app.jsonl 最近 N 行 (JSON 格式, 给程序分析用)
  Future<List<Map<String, Object?>>> readRecentJsonl({int lines = 100}) async {
    if (!_initialized || _jsonlFile == null) return [];
    try {
      await _writeChain;
      final content = await _jsonlFile!.readAsString();
      final all = content.split('\n').where((l) => l.isNotEmpty).toList();
      final start = all.length > lines ? all.length - lines : 0;
      return all
          .sublist(start)
          .map((l) => jsonDecode(l) as Map<String, Object?>)
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ============================================================
  // 内部
  // ============================================================

  /// 串行化双写 (human 格式 + JSON 格式)
  void _writeBoth(String humanLine, String jsonLine) {
    _writeChain = _writeChain.then((_) async {
      try {
        await _maybeRotate(_logFile);
        await _logFile?.writeAsString('$humanLine\n',
            mode: FileMode.append, flush: true);
        await _maybeRotate(_jsonlFile);
        await _jsonlFile?.writeAsString('$jsonLine\n',
            mode: FileMode.append, flush: true);
      } catch (_) {
        // 写文件失败不能 crash app
      }
    });
  }

  /// 启动时同步写 (保证启动标记一定写进去)
  Future<void> _appendSync(LogEntry e) async {
    final human = e.formatHuman();
    final json = e.formatJson();
    _writeChain = _writeChain.then((_) async {
      try {
        await _logFile?.writeAsString('$human\n',
            mode: FileMode.append, flush: true);
        await _jsonlFile?.writeAsString('$json\n',
            mode: FileMode.append, flush: true);
      } catch (_) {}
    });
    await _writeChain;
  }

  /// 文件大小超限滚动 (rename .log -> .log.1, 保留最近 1 个备份)
  Future<void> _maybeRotate(File? f) async {
    if (f == null) return;
    try {
      if (!await f.exists()) return;
      final size = await f.length();
      if (size < _maxFileBytes) return;
      final backup = File('${f.path}.1');
      if (await backup.exists()) {
        await backup.delete();
      }
      await f.rename(backup.path);
      // recreate empty
      await f.create();
    } catch (_) {
      // 滚动失败不阻塞主流程
    }
  }

  int _cidCounter = 0;
  String _newCorrelationId() {
    _cidCounter++;
    return 'cid${DateTime.now().millisecondsSinceEpoch}_$_cidCounter';
  }

  String _getFlutterInfo() {
    try {
      return 'Flutter Dart ${Platform.version.split(" ").first} on "${Platform.operatingSystem}"';
    } catch (_) {
      return 'Flutter unknown';
    }
  }
}
