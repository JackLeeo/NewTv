// lib/services/nodejs_platform_android.dart
//
// Android 端 Node.js 实现（**骨架/占位**）
// -----------------------------------------------------------------------------
// Android 端理论上应该:
//   - 嵌入 libnode.a（来自 nodejs-mobile-android）
//   - 写 JNI 调用 libnode 启动 Node.js
//   - 通过 platform channel 调 Kotlin 端
//
// **当前阶段先 throw UnimplementedError**——iOS 是最终目标，Android 留接口占位。
// 等 iOS 链路跑通后再补 Android 端 native 实现。

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier;

import 'nodejs_platform.dart';

class AndroidNodeJSPlatform implements NodeJSPlatform {
  AndroidNodeJSPlatform({
    required this.onNodeReadyChanged,
    required this.onManagementPortChanged,
    required this.onSpiderPortChanged,
  });

  final ValueNotifier<bool> onNodeReadyChanged;
  final ValueNotifier<int> onManagementPortChanged;
  final ValueNotifier<int> onSpiderPortChanged;

  @override
  bool get isRunning => false;
  @override
  bool get isNodeReady => false;
  @override
  int get nativeServerPort => 0;
  @override
  int get managementPort => 0;
  @override
  int get spiderPort => 0;

  Never _unimplemented(String method) {
    throw UnimplementedError(
        'Android 端 Node.js 集成尚未实现 ($method)。'
        'iOS 是当前优先目标。');
  }

  @override
  Future<bool> startNodeJS() async => _unimplemented('startNodeJS');

  @override
  void stopNodeJS() => _unimplemented('stopNodeJS');

  @override
  void forceResetRunningState() => _unimplemented('forceResetRunningState');

  @override
  Future<bool> waitForNodeReady() async => _unimplemented('waitForNodeReady');

  @override
  Future<bool> waitForSpiderPort() async => _unimplemented('waitForSpiderPort');

  @override
  Future<(bool success, String? message)> loadSource(String urlString) async =>
      _unimplemented('loadSource');

  @override
  Future<bool> deleteSource() async => _unimplemented('deleteSource');

  @override
  Future<String> getDocumentsSourcePath() async {
    _unimplemented('getDocumentsSourcePath');
  }

  @override
  Future<bool> isNodeRuntimeInstalled() async {
    _unimplemented('isNodeRuntimeInstalled');
  }

  @override
  void setNativeServerPort(int port) {
    _unimplemented('setNativeServerPort');
  }

  @override
  void onPortReceived(int port, String type) {
    _unimplemented('onPortReceived');
  }

  @override
  void onMessage(String message) {
    _unimplemented('onMessage');
  }

  @override
  Future<void> downloadAndExtractNodeRuntime(
    NodeDownloadConfig cfg, {
    void Function(double progress)? onProgress,
  }) async {
    _unimplemented('downloadAndExtractNodeRuntime');
  }
}
