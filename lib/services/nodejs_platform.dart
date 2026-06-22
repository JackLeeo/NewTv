// lib/services/nodejs_platform.dart
//
// Node.js 跨平台抽象层
// -----------------------------------------------------------------------------
// 三端用各自的 Node.js 嵌入方案：
//   - **Windows**: Process.start(node.exe) + 按需下载 zip
//   - **iOS**:     platform channel → Swift → NodeMobile.xcframework
//   - **Android**: platform channel → Kotlin → libnode (JNI)
//
// 跨端统一接口在 [NodeJSPlatform] 抽象类里。
// NodeJSManager 用 `Platform.isXxx` 选具体实现。

import 'dart:async';

/// Node.js 下载配置
///
/// `version.json` 里的字段。当前**只对 Windows 有意义**（iOS / Android 不需要下载 runtime）
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
      version: json['version'] as String,
      mirror: json['mirror'] as String? ?? '',
      downloadUrl: json['download_url'] as String,
      exeRelativePathInZip:
          json['exe_relative_path_in_zip'] as String? ?? '',
      zipSizeHintMb: json['zip_size_hint_mb'] as int? ?? 0,
      minAppVersion: json['min_app_version'] as String? ?? '1.0.0',
    );
  }
}

/// Node.js 平台抽象接口
///
/// **三端必须实现**的核心方法（启动/停止/加载源/路径）。
///
/// **仅 Windows 实现**的运行时下载方法（iOS 用 NodeMobile framework，
/// Android 用 libnode 静态库，都不需要运行时下载）。
abstract class NodeJSPlatform {
  // ============================================================
  // 运行时状态
  // ============================================================
  bool get isRunning;
  bool get isNodeReady;
  int get nativeServerPort;
  int get managementPort;
  int get spiderPort;

  // ============================================================
  // 启动 / 停止 Node.js
  // ============================================================

  /// 启动 Node.js 进程
  ///
  /// - Windows: 调 `Process.start(node.exe, [main.js, --native-port ...])`
  /// - iOS:     调 platform channel → Swift → `node_start(argc, argv)`
  /// - Android: 调 platform channel → Kotlin → JNI 调 libnode
  ///
  /// 三端都需要：
  /// 1. 把 `main.js` 准备好（Windows: rootBundle→本地；iOS: bundle resource；Android: assets）
  /// 2. 起本地 HTTP server 收 Node.js 通知（用 dart:io，三端统一）
  /// 3. 通过 `--native-port` 把 HTTP server 端口传给 Node.js
  ///
  /// 返回 `isNodeReady`（Node.js 已发出 ready 消息）
  Future<bool> startNodeJS();

  void stopNodeJS();

  void forceResetRunningState();

  /// 等待 Node.js 发出 `ready` 消息
  Future<bool> waitForNodeReady();

  /// 等待 Spider HTTP server 端口打开
  Future<bool> waitForSpiderPort();

  // ============================================================
  // 源管理
  // ============================================================

  /// 从 URL 加载源（MD5 校验 + 下载 + 通过 management 端口通知 Node.js）
  ///
  /// 返回 `(success, message?)`
  Future<(bool success, String? message)> loadSource(String urlString);

  /// 删除已下载的源文件
  Future<bool> deleteSource();

  /// 文档目录下 nodejs source 目录的绝对路径
  /// - Windows / Android: `getApplicationDocumentsDirectory()/nodejs/source`
  /// - iOS:               `<Documents>/nodejs-project/src/source`
  Future<String> getDocumentsSourcePath();

  // ============================================================
  // 运行时下载（仅 Windows）
  // ============================================================

  /// Node.js 运行时是否已就绪
  ///
  /// - Windows: 检查 `<AppSupport>/node-runtime/node.exe` 是否存在
  /// - iOS:     永远返回 `true`（NodeMobile.xcframework 嵌进 bundle）
  /// - Android: 永远返回 `true`（libnode.a 编译进 APK）
  Future<bool> isNodeRuntimeInstalled();

  /// 由 [NodeJSManager] 在启动 HTTP server 后注入端口
  /// Node.js 通过 `--native-port $port` 拿到这个端口，回调通知 Dart
  void setNativeServerPort(int port);

  /// HTTP server 收到 `/onCatPawOpenPort?port=&type=` 时调用
  void onPortReceived(int port, String type);

  /// HTTP server 收到 `/onMessage` 时调用
  void onMessage(String message);

  /// 下载并解压 Node.js 运行时
  ///
  /// **仅 Windows 需要**。iOS / Android 端直接返回。
  /// [cfg] 由调用方提供（默认从 `version.json` 加载）
  /// [onProgress] 进度回调 0.0~1.0
  Future<void> downloadAndExtractNodeRuntime(
    NodeDownloadConfig cfg, {
    void Function(double progress)? onProgress,
  });
}
