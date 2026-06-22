import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

/// 画中画管理器 - 桌面端 (Windows/macOS/Linux) 通过 window_manager
/// 实现真正的桌面级悬浮窗口：
///   - 窗口置顶 (alwaysOnTop)
///   - 调整窗口为小尺寸悬浮窗 (默认 480x270 - 16:9)
///   - 移动到屏幕右下角
///
/// 与 Swift 的 AVPictureInPictureController 行为类似：
///   - 视频始终在播放
///   - 窗口可拖动
///   - 单击视频可退出 PiP 恢复原窗口
///
/// 视频播放器由调用方通过 [VideoPlayerPipController.attach] 注入，
/// 这样可以避免重建 Player 实例，保留播放状态。
class VideoPlayerPip {
  static final VideoPlayerPip instance = VideoPlayerPip._();
  VideoPlayerPip._();

  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  // ========== 状态 ==========
  bool _isActive = false;
  Rect? _savedBounds;
  Player? _attachedPlayer;

  /// 当前是否处于画中画模式
  bool get isActive => _isActive;

  /// 监听 PiP 状态变化（用于 detail 页同步隐藏 AppBar 等 UI）
  final ValueNotifier<bool> activeNotifier = ValueNotifier<bool>(false);

  /// 当前已附加的 Player（用于上层构建 PiP 预览视图）
  Player? get attachedPlayer => _attachedPlayer;

  // ========== 入口 API ==========

  /// 附加播放器到 PiP 模块（不创建新 Player，复用已有实例）
  void attachPlayer(Player player) {
    _attachedPlayer = player;
  }

  /// 解除附加
  void detachPlayer() {
    _attachedPlayer = null;
  }

  /// 进入画中画
  Future<void> enter() async {
    if (_isActive) return;
    if (_attachedPlayer == null) {
      debugPrint('[VideoPlayerPip] enter: no player attached');
      return;
    }
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      // 移动端平台：不支持桌面级 PiP 浮动窗口
      // 可以使用系统 PiP API（暂未实现）
      debugPrint('[VideoPlayerPip] enter: unsupported platform');
      return;
    }

    try {
      // 1) 保存当前窗口状态（仅大小/位置）
      _savedBounds = await windowManager.getBounds();
      // 注意：不再保存/恢复 OS 全屏 —— 全屏由 VideoPlayerWidget 的
      // _toggleNativeFullscreen 通过 media_kit 的 Utils.EnterNativeFullscreen
      // 管理，与 windowManager.setFullScreen 不是同一个 API，
      // 互相调用会导致窗口状态混乱。

      // 2) 设置窗口为可调整大小（解除最小尺寸限制以便恢复）
      await windowManager.setMinimumSize(const Size(240, 160));

      // 3) 计算悬浮窗位置：屏幕右下角，留 16px 边距
      const pipSize = Size(480, 270); // 16:9
      final screenBounds = _getScreenBounds();
      final pipPosition = Offset(
        screenBounds.right - pipSize.width - 16,
        screenBounds.bottom - pipSize.height - 16,
      );

      // 4) 调整窗口大小并移动到右下角
      await windowManager.setSize(pipSize);
      await windowManager.setPosition(pipPosition);

      // 5) 隐藏窗口标题栏（最大/最小/关闭那一栏），让 PiP 看起来更纯粹
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);

      // 6) 设置窗口置顶
      await windowManager.setAlwaysOnTop(true);

      _isActive = true;
      activeNotifier.value = true;
      debugPrint('[VideoPlayerPip] enter: PiP active');
    } catch (e, st) {
      debugPrint('[VideoPlayerPip] enter failed: $e\n$st');
      _isActive = false;
      activeNotifier.value = false;
    }
  }

  /// 退出画中画
  Future<void> exit() async {
    if (!_isActive) return;
    try {
      // 1) 取消置顶
      await windowManager.setAlwaysOnTop(false);

      // 2) 恢复窗口标题栏显示
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);

      // 3) 恢复窗口大小与位置
      if (_savedBounds != null) {
        await windowManager.setSize(_savedBounds!.size);
        await windowManager.setPosition(_savedBounds!.topLeft);
        // 不再恢复 OS 全屏 —— 见 enter() 注释
      }
    } catch (e, st) {
      debugPrint('[VideoPlayerPip] exit failed: $e\n$st');
    } finally {
      _isActive = false;
      _savedBounds = null;
      activeNotifier.value = false;
      debugPrint('[VideoPlayerPip] exit: PiP inactive');
    }
  }

  /// 切换画中画
  Future<void> toggle() async {
    if (_isActive) {
      await exit();
    } else {
      await enter();
    }
  }

  /// 获取屏幕可用区域（用于计算 PiP 悬浮窗位置）
  Rect _getScreenBounds() {
    // 使用 Flutter 的 platformDispatcher 获取屏幕尺寸
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final dpr = view.devicePixelRatio;
    final physicalSize = view.physicalSize;
    final logicalSize = Size(physicalSize.width / dpr, physicalSize.height / dpr);
    final offset = view.viewPadding.top > 0
        ? Offset.zero
        : Offset.zero; // 简化：未考虑多屏场景
    return Rect.fromLTWH(
      offset.dx,
      offset.dy,
      logicalSize.width,
      logicalSize.height,
    );
  }
}
