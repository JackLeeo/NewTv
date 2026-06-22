import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// 窗口级全屏管理器 - 桌面端通过 `window_manager.setFullScreen(true)` 实现 OS 全屏
///
/// **为什么用 setFullScreen 而不是手动 setSize + setPosition + setTitleBarStyle**：
/// `window_manager.setFullScreen(true)` 内部用 Win32 `SetWindowLongPtr` 改
/// `GWL_STYLE` 加 `WS_POPUP`，**移除 `WS_OVERLAPPEDWINDOW`** 风格。
///
/// 这是**关键**：普通窗口（`WS_OVERLAPPEDWINDOW`）受 Windows snap-to-workarea
/// 限制，`SetWindowPos(0, 0, cx, cy)` 即使 cx/cy 等于 monitor 物理像素，
/// Windows 也会把窗口 clamp 到 work area（不含 taskbar 区域），导致：
/// - 底部无法覆盖 Windows 开始菜单栏
/// - 多显示器场景下窗口被错位
///
/// `WS_POPUP` 风格窗口**不受** work area 限制，可以直接覆盖整个 screen
/// （含 taskbar 区域）。这才是真正的 OS 全屏。
///
/// **ANGLE 黑屏问题**：
/// 改 `GWL_STYLE` 会触发 mpv ANGLE surface 重建，与 Video widget 的 texture 通道
/// 重建存在竞态。VideoPlayerWidget 通过 `_videoRebuildKey++` 强制重建 Video widget
/// 绕过，详见 `VideoPlayerWidget._onWindowFullScreenChanged`。
class WindowFullScreen {
  static final WindowFullScreen instance = WindowFullScreen._();
  WindowFullScreen._();

  bool _isActive = false;
  Rect? _savedBounds;

  /// 当前是否处于全屏模式
  bool get isActive => _isActive;

  /// 监听全屏状态变化（用于上层同步 immersive 模式 & icon 切换）
  final ValueNotifier<bool> activeNotifier = ValueNotifier<bool>(false);

  // ============================================================
  // 入口 API
  // ============================================================

  /// 进入全屏
  ///
  /// **关键根因与修复**：
  /// 1. Windows `SetWindowPos` 在窗口 maximize 状态时**忽略** size 变化
  /// 2. window_manager 的 `restore()` 用 `PostMessage(SC_RESTORE)` 是**异步**的
  /// 修复：先 restore + **polling** 等待窗口状态稳定
  /// 3. **`WS_OVERLAPPEDWINDOW` 风格受 work area 限制**——窗口被 Windows
  ///    clamp 到 work area（不含 taskbar），无法覆盖开始菜单栏
  /// 修复：用 `window_manager.setFullScreen(true)`，内部切到 `WS_POPUP` 风格
  Future<void> enter() async {
    if (_isActive) return;
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      return;
    }
    try {
      // 0) 防御性：restore 窗口（处理 minimize/maximize）
      // `restore()` 是 `PostMessage(SC_RESTORE)` 异步发的，必须 polling 等
      try {
        if (await windowManager.isMaximized() ||
            await windowManager.isMinimized()) {
          await windowManager.restore();
          for (int i = 0; i < 30; i++) {
            final isMax = await windowManager.isMaximized();
            final isMin = await windowManager.isMinimized();
            debugPrint(
                '[WindowFullScreen] enter: poll[$i] isMax=$isMax isMin=$isMin');
            if (!isMax && !isMin) break;
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
      } catch (e) {
        debugPrint('[WindowFullScreen] enter: restore failed: $e');
      }

      // 1) 保存当前窗口状态（仅大小/位置）
      _savedBounds = await windowManager.getBounds();
      debugPrint('[WindowFullScreen] enter: saved bounds = $_savedBounds');

      // 2) 进入全屏 - window_manager 内部用 SetWindowLongPtr 加 WS_POPUP
      // + SetWindowPos 调到 (0, 0, SM_CXSCREEN, SM_CYSCREEN)
      // - WS_POPUP 风格不受 work area 限制，直接覆盖 taskbar
      // - setFullScreen 内部会保存原 style 和 bounds，exit 时恢复
      await windowManager.setFullScreen(true);
      debugPrint(
          '[WindowFullScreen] enter: setFullScreen done, current bounds = ${await windowManager.getBounds()}');

      // **关键**：翻转 _isActive 必须在 setFullScreen 完成之后
      // 这样 listener（_isNativeFullscreen 同步）只会在窗口真正调整好之后触发，
      // 避免"窗口还没全屏但 icon 已经切换"或反过来的时序错位
      _isActive = true;
      activeNotifier.value = true;
      debugPrint('[WindowFullScreen] enter: fullscreen active');
    } catch (e, st) {
      debugPrint('[WindowFullScreen] enter failed: $e\n$st');
      _isActive = false;
      activeNotifier.value = false;
    }
  }

  /// 退出全屏
  ///
  /// `window_manager.setFullScreen(false)` 内部恢复 saved style 和 bounds。
  Future<void> exit() async {
    if (!_isActive) return;
    try {
      // setFullScreen(false) 内部会恢复原 WS_OVERLAPPEDWINDOW style + saved bounds
      await windowManager.setFullScreen(false);
      debugPrint(
          '[WindowFullScreen] exit: setFullScreen(false) done, current bounds = ${await windowManager.getBounds()}');
    } catch (e, st) {
      debugPrint('[WindowFullScreen] exit failed: $e\n$st');
    } finally {
      _isActive = false;
      _savedBounds = null;
      activeNotifier.value = false;
      debugPrint('[WindowFullScreen] exit: fullscreen inactive');
    }
  }

  /// 切换全屏
  Future<void> toggle() async {
    if (_isActive) {
      await exit();
    } else {
      await enter();
    }
  }
}
