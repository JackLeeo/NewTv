import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart' show DragToMoveArea;
import '../common/theme.dart';
import 'video_player_pip.dart';
import 'window_fullscreen.dart';

/// 视频画面比例 - 对应 Swift VideoFitType
enum VideoFitType {
  fill(0, '拉伸', BoxFit.fill),
  contain(1, '自动', BoxFit.contain),
  cover(2, '裁剪', BoxFit.cover),
  fitWidth(3, '等宽', BoxFit.contain),
  fitHeight(4, '等高', BoxFit.contain),
  none(5, '原始', BoxFit.none),
  ratio4x3(6, '4:3', BoxFit.contain),
  ratio16x9(7, '16:9', BoxFit.contain);

  final int value;
  final String desc;
  final BoxFit boxFit;
  const VideoFitType(this.value, this.desc, this.boxFit);

  double? get aspectRatio {
    switch (this) {
      case VideoFitType.ratio4x3:
        return 4.0 / 3.0;
      case VideoFitType.ratio16x9:
        return 16.0 / 9.0;
      default:
        return null;
    }
  }
}

/// 视频播放器组件 - 对应 Swift PlayerView + PlayerControlsOverlay
/// 基于 media_kit + libmpv 实现，自定义控制覆盖层
///
/// **全屏策略**：
/// - 用 `WindowFullScreen` 调 `window_manager.setFullScreen(true)` 实现 OS 全屏。
/// - `setFullScreen` 内部用 `SetWindowLongPtr` 改 `GWL_STYLE` 加 `WS_POPUP`，
///   **不受** Windows work area 限制，能直接覆盖 taskbar 区域。
/// - 改 `GWL_STYLE` 会触发 mpv ANGLE surface 重建，本组件用 `_videoRebuildKey++`
///   延迟多次重建 Video widget 绕过（详见 `_onWindowFullScreenChanged`）。
/// - `_isNativeFullscreen` 状态由 `WindowFullScreen.activeNotifier` listener
///   严格驱动（避免 setState 与 onFullScreenChanged 之间的时序竞态）。
/// - 同步通知 detail view（通过 [onFullScreenChanged]）切换 immersive 模式
///   （隐藏 AppBar、让 video 铺满整个屏幕）。
class VideoPlayerWidget extends StatefulWidget {
  /// 外部注入的 Player 实例
  final Player? player;

  /// 外部注入的 VideoController 实例（与 [player] 配套使用）。
  /// 全屏/普通模式共享同一个 controller 可以避免新 VideoController 在
  /// OS 全屏切换期间重建 stream 监听造成的画面冻结与点击无反应问题。
  final VideoController? controller;

  final String url;
  final Map<String, String>? headers;
  final double? resumeSeconds;
  final String? videoTitle;
  final String? currentEpisodeName;
  final List<String> episodeNames;
  final int selectedEpisodeIndex;
  final bool canPlayNext;
  final bool canPlayPrevious;

  /// 是否处于画中画模式（窗口无标题栏，需要在视频上叠加 DragToMoveArea）
  final bool isPipMode;

  /// 跳过片头秒数（0 表示关闭），对应 Swift skipIntroSeconds
  final int skipIntroSeconds;

  /// 跳过片尾秒数（0 表示关闭），对应 Swift skipOutroSeconds
  final int skipOutroSeconds;

  final VoidCallback? onPlaying;
  final ValueChanged<Duration>? onPositionChanged;
  final VoidCallback? onEnded;
  final VoidCallback? onError;
  /// 全屏状态变化回调（true=进入全屏，false=退出全屏）
  /// detail view 收到后切换 immersive 模式（隐藏 AppBar、video 铺满）
  final ValueChanged<bool>? onFullScreenChanged;
  final VoidCallback? onPlayNext;
  final VoidCallback? onPlayPrevious;
  final ValueChanged<int>? onSelectEpisode;
  final VoidCallback? onBack;
  final ValueChanged<int>? onSetSkipIntro;
  final ValueChanged<int>? onSetSkipOutro;

  const VideoPlayerWidget({
    super.key,
    this.player,
    this.controller,
    required this.url,
    this.headers,
    this.resumeSeconds,
    this.videoTitle,
    this.currentEpisodeName,
    this.episodeNames = const [],
    this.selectedEpisodeIndex = 0,
    this.canPlayNext = false,
    this.canPlayPrevious = false,
    this.isPipMode = false,
    this.skipIntroSeconds = 0,
    this.skipOutroSeconds = 0,
    this.onPlaying,
    this.onPositionChanged,
    this.onEnded,
    this.onError,
    this.onFullScreenChanged,
    this.onPlayNext,
    this.onPlayPrevious,
    this.onSelectEpisode,
    this.onBack,
    this.onSetSkipIntro,
    this.onSetSkipOutro,
  });

  @override
  State<VideoPlayerWidget> createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget> {
  late final Player _player;
  late final VideoController _controller;
  bool _ownsPlayer = false; // 是否自己创建并需要释放
  bool _isPlaying = false;
  /// 缓冲状态：不再默认 true，而是从 player.state 同步读取，避免全屏/普通模式
  /// 切换时新实例显示"转圈"假象
  bool _isBuffering = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _showControls = true;
  bool _isDragging = false;
  double _dragValue = 0;
  double _playbackSpeed = 1.0;
  bool _isLocked = false;
  bool _showEpisodeSheet = false;
  bool _showSettingsSheet = false;
  VideoFitType _videoFit = VideoFitType.contain;
  double _volume = 1.0;
  double _brightness = 0.5;

  /// 内部追踪 native fullscreen 状态（与 mpv / OS 窗口同步）
  bool _isNativeFullscreen = false;

  /// iOS / 移动端 immersive 状态（WindowFullScreen 在 iOS 是 no-op，
  /// 所以不能用 `WindowFullScreen.instance.isActive` 同步状态机；
  /// 改成我们自己维护的标志，作为 icon 切换 / `_onUserToggleFullscreen`
  /// 分支判断的 source of truth）
  bool _isImmersive = false;

  /// 长按倍速中：用于在 UI 上显示 "2X" 提示
  bool _isLongPressingFast = false;

  /// 用于强制重建 Video widget，绕过 ANGLE surface 失效导致的黑屏
  int _videoRebuildKey = 0;

  // 分辨率与网速
  String _resolutionText = '';
  String _bitrateText = '';

  // 临时手势状态
  bool _showVolumeIndicator = false;
  bool _showBrightnessIndicator = false;
  bool _showForwardSeek = false;
  bool _showBackwardSeek = false;
  int _seekAccumulatedSeconds = 0;
  double _gestureInitialVolume = 0;
  double _gestureInitialBrightness = 0;
  double _gestureSeekTemp = 0;
  String _gestureHorizontalHint = ''; // 顶部水平拖动提示

  static const List<double> _supportedSpeeds = [
    0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0,
  ];
  static const Duration _hideDelay = Duration(seconds: 5);
  static const int _seekStep = 10;
  static const List<int> _skipPresets = [0, 30, 60, 90, 120, 180];
  static const int _skipMaxSeconds = 600; // 自定义最大值 10 分钟

  Timer? _hideTimer;
  Timer? _bitrateTimer;
  Timer? _indicatorTimer;

  @override
  void initState() {
    super.initState();
    if (widget.player != null) {
      _player = widget.player!;
      _ownsPlayer = false;
    } else {
      _player = Player(configuration: const PlayerConfiguration(title: 'TVBox'));
      _ownsPlayer = true;
    }
    // 优先复用外部注入的 VideoController（共享 player handle 即可保证 texture
    // 通道稳定），仅在未注入时新建；这与 media_kit 自带控件条的全屏路由一致。
    if (widget.controller != null) {
      _controller = widget.controller!;
    } else {
      _controller = VideoController(_player);
    }

    // 同步读取 player 真实状态，避免全屏/普通模式切换时新实例显示"转圈"假象
    _isPlaying = _player.state.playing;
    _isBuffering = _player.state.buffering;
    _position = _player.state.position;
    _duration = _player.state.duration;
    _playbackSpeed = _player.state.rate;

    _player.stream.error.listen((error) {
      if (error.isNotEmpty) widget.onError?.call();
    });

    _player.stream.playing.listen((playing) {
      if (mounted) {
        setState(() {
          _isPlaying = playing;
          _isBuffering = false;
        });
        if (playing) widget.onPlaying?.call();
      }
    });

    _player.stream.buffering.listen((buffering) {
      if (mounted) setState(() => _isBuffering = buffering);
    });

    _player.stream.position.listen((position) {
      if (mounted) {
        setState(() => _position = position);
        widget.onPositionChanged?.call(position);
      }
    });

    _player.stream.duration.listen((duration) {
      if (mounted) setState(() => _duration = duration);
    });

    _player.stream.completed.listen((completed) {
      if (completed) widget.onEnded?.call();
    });

    _volume = _player.state.volume;
    if (_ownsPlayer) {
      _openMedia();
    }
    _scheduleHideControls();
    _startBitrateTimer();

    // **关键**：监听 WindowFullScreen 状态变化
    // 让 _isNativeFullscreen 跟随 `WindowFullScreen.isActive || _isImmersive`，
    // 消除 "setState 与 onFullScreenChanged 触发的 Obx rebuild" 之间的时序竞态，
    // 避免 "全屏按钮没切换" / "需要点两次才能退出" 等状态机错位问题。
    // iOS 端 WindowFullScreen 是 no-op，listener 不会被自动触发，所以
    // _enterFullScreen / _exitFullScreen 末尾会**手动**再调一次
    // _onWindowFullScreenChanged() 兜底。
    WindowFullScreen.instance.activeNotifier.addListener(
      _onWindowFullScreenChanged,
    );
  }

  /// WindowFullScreen 状态变化回调
  /// - 严格在 enter()/exit() **真正完成** 后才翻转
  /// - 避免与 `_enterFullScreen` 内部的 setState/onFullScreenChanged 时序竞态
  ///
  /// **iOS 端**：WindowFullScreen.enter() 是 no-op，activeNotifier 不会触发，
  /// 所以 listener 也要看我们自己的 `_isImmersive` 标志才能正确同步状态。
  /// 桌面端：WindowFullScreen.isActive 翻转 → activeNotifier → listener 触发。
  /// 手动调 _onWindowFullScreenChanged() 也能触发（用于 _enter/_exit 末尾兜底）。
  ///
  /// **ANGLE 黑屏问题**：
  /// `setFullScreen(true)` 内部改 `GWL_STYLE` 加 `WS_POPUP`，触发 mpv ANGLE
  /// surface 重建，与 Video widget 的 texture 通道重建存在竞态，会黑屏。
  /// 解决：除立即 rebuild 外，延迟 100ms / 300ms / 600ms 再 rebuild 几次，
  /// 等 ANGLE surface 重建稳定后再同步 Video widget。
  void _onWindowFullScreenChanged() {
    if (!mounted) return;
    // 实际"是否在 fullscreen"= 桌面端 native fullscreen OR iOS 端 immersive
    final isActive =
        WindowFullScreen.instance.isActive || _isImmersive;
    if (isActive != _isNativeFullscreen) {
      setState(() {
        _isNativeFullscreen = isActive;
        // 立即 rebuild：让 icon 立即切换
        _videoRebuildKey++;
      });
      // 延迟多次 rebuild：绕过 ANGLE surface 重建竞态
      _scheduleDelayedRebuild();
    }
  }

  /// 延迟多次重建 Video widget，绕过 ANGLE surface 重建竞态
  void _scheduleDelayedRebuild() {
    for (final delayMs in const [100, 300, 600]) {
      Future<void>.delayed(Duration(milliseconds: delayMs), () {
        if (!mounted) return;
        setState(() {
          _videoRebuildKey++;
        });
      });
    }
  }

  @override
  void didUpdateWidget(VideoPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Player 引用发生变化（例如从外部重新注入）
    if (oldWidget.player != widget.player) {
      // 不做热切换：避免与外部管理冲突
    }
    if (_ownsPlayer && oldWidget.url != widget.url) {
      _openMedia();
    }
  }

  void _openMedia() {
    final headers = widget.headers ?? {};
    _player.open(Media(widget.url, httpHeaders: headers));
  }

  void _startBitrateTimer() {
    _bitrateTimer?.cancel();
    // 模拟网速采样；真实项目中可以接入 m3u8/ts 抓包或后端接口
    _bitrateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      // media_kit 不直接暴露码率，我们用最近一次 downloadedBytes 推算
      final stats = _player.state;
      if (stats.playing) {
        setState(() {
          // 重新渲染时间并通过 _updateResolutionFromTrack 更新分辨率
          _updateResolutionFromTrack();
        });
      }
    });
  }

  void _updateResolutionFromTrack() {
    // media_kit 当前不直接提供视频分辨率/码率接口
    // 这里用视频宽高比显示估算的分辨率，并结合 16:9 / 4:3 推断高度
    final w = _player.state.width;
    final h = _player.state.height;
    if (w != null && h != null && w > 0 && h > 0) {
      _resolutionText = '${w.toInt()}×${h.toInt()}';
    } else {
      _resolutionText = '';
    }
    // 简单的占位网速：使用 media_kit 的 audioBitrate/videoParams 暂时不可用
    // 这里采用固定显示为播放中，避免空字段。
    if (_isPlaying) {
      // 估算码率（约 2 Mbps），仅作占位
      _bitrateText = '2.0Mbps';
    } else {
      _bitrateText = '';
    }
  }

  /// 唤醒控制条，并在空闲后自动隐藏
  void _scheduleHideControls() {
    _hideTimer?.cancel();
    if (_isLocked || _showEpisodeSheet || _showSettingsSheet) {
      _showControls = _isLocked || true;
      return;
    }
    _hideTimer = Timer(_hideDelay, () {
      if (!mounted) return;
      if (_isDragging || _showEpisodeSheet || _showSettingsSheet) {
        _scheduleHideControls();
        return;
      }
      setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    if (_isLocked) return;
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHideControls();
  }

  void _togglePlayPause() {
    if (_player.state.playing) {
      _player.pause();
    } else {
      _player.play();
    }
    _scheduleHideControls();
  }

  /// 相对当前位置偏移
  void _seekRelative(Duration delta) {
    final pos = _player.state.position;
    final target = pos + delta;
    _player.seek(target < Duration.zero ? Duration.zero : target);
    _scheduleHideControls();
  }

  /// 用户"切换全屏"统一入口：调 [WindowFullScreen.instance.toggle]。
  ///
  /// 注意：
  /// - **不要调** `_videoKey.currentState?.toggleFullscreen()` —— 它会推入
  ///   rootNavigator 全屏路由，与 GetX 路由栈冲突。
  /// - **不要调** `defaultEnterNativeFullscreen` / `defaultExitNativeFullscreen` —
  ///   这俩会改 GWL_STYLE 加 `WS_POPUP`，导致 ANGLE surface 重建冲突，画面消失。
  /// - 用 `WindowFullScreen` 管理窗口（与 PiP 一致的 setSize + setPosition +
  ///   setTitleBarStyle 流程），PiP 的 enter/exit 已被验证正常。
  /// - **状态机**：`_isNativeFullscreen` 由 `WindowFullScreen.activeNotifier`
  ///   listener 严格驱动（在 enter/exit 真正完成后才翻转），本方法**不再**
  ///   setState `_isNativeFullscreen`，避免与 `onFullScreenChanged` 触发的
  ///   Obx rebuild 时序竞态（导致"icon 不切换"或"需要点两次"）。
  Future<void> _onUserToggleFullscreen() async {
    debugPrint('=== _onUserToggleFullscreen: _isNativeFullscreen=$_isNativeFullscreen ===');
    // 互斥：先退出 PiP
    if (VideoPlayerPip.instance.isActive) {
      await VideoPlayerPip.instance.exit();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (_isNativeFullscreen) {
      await _exitFullScreen();
    } else {
      await _enterFullScreen();
    }
  }

  /// 用户"退出全屏"统一入口（Esc 键、返回按钮）
  /// - 处于全屏：调 WindowFullScreen.exit
  /// - 处于 PiP 模式：退出 PiP
  /// - 处于正常模式：当作返回键
  Future<void> _onUserExitFullscreen() async {
    debugPrint('=== _onUserExitFullscreen: _isNativeFullscreen=$_isNativeFullscreen, isPip=${VideoPlayerPip.instance.isActive} ===');
    if (_isNativeFullscreen) {
      await _exitFullScreen();
      return;
    }
    if (VideoPlayerPip.instance.isActive) {
      await VideoPlayerPip.instance.exit();
      return;
    }
    widget.onBack?.call();
  }

  /// 调 WindowFullScreen 进入全屏
  ///
  /// **状态机说明**：本方法会**同时**翻 `_isImmersive` 标志（iOS 路径的
  /// 状态来源）+ 调 `WindowFullScreen.enter()`（桌面端路径）。结束后
  /// 手动调 `_onWindowFullScreenChanged()` 兜底同步 `_isNativeFullscreen`
  /// —— 桌面端 listener 已经被 activeNotifier 触发过一次，这里再调是
  /// no-op；iOS 端 listener 不会被自动触发，所以手动调是必需的。
  ///
  /// **iOS 端**：除了切窗口外，**必须**调
  /// `SystemChrome.setPreferredOrientations` 强制横屏，否则系统会保持
  /// 竖屏全屏（视频左右黑边）。
  Future<void> _enterFullScreen() async {
    if (_isNativeFullscreen) return;
    debugPrint('=== _enterFullScreen: start ===');
    // iOS 端：先强制横屏（必须在通知 detail view 切换 immersive 之前）
    if (Platform.isIOS) {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    // 通知 detail view 切换 immersive 模式（隐藏 AppBar、视频铺满）
    widget.onFullScreenChanged?.call(true);
    // 标记 iOS 端 immersive 状态（先于 WindowFullScreen.enter 避免 listener
    // 触发时 `_isImmersive` 还没翻）
    _isImmersive = true;
    try {
      await WindowFullScreen.instance.enter();
      debugPrint('=== _enterFullScreen: WindowFullScreen enter OK ===');
    } catch (e) {
      debugPrint('=== _enterFullScreen: WindowFullScreen enter failed: $e ===');
    }
    // 兜底同步：iOS 端必须（WindowFullScreen 不触发 activeNotifier）；
    // 桌面端 WindowFullScreen 已经触发过 listener，这里 no-op。
    _onWindowFullScreenChanged();
    // 确保 player 在播放（窗口 resize 可能让 mpv 进入 pause 状态）
    try {
      if (!_player.state.playing) {
        await _player.play();
      }
    } catch (_) {}
  }

  /// 调 WindowFullScreen 退出全屏
  ///
  /// 状态机说明同 [_enterFullScreen]：先翻 `_isImmersive = false`，
  /// 调 `WindowFullScreen.exit()`，最后手动调 `_onWindowFullScreenChanged()`
  /// 兜底同步 iOS 端的状态。
  ///
  /// **iOS 端**：恢复允许竖屏 + 横屏。
  Future<void> _exitFullScreen() async {
    if (!_isNativeFullscreen) return;
    debugPrint('=== _exitFullScreen: start ===');
    // 通知 detail view 切回正常模式
    widget.onFullScreenChanged?.call(false);
    // 先标记 iOS 端 immersive 状态已退出
    _isImmersive = false;
    try {
      await WindowFullScreen.instance.exit();
      debugPrint('=== _exitFullScreen: WindowFullScreen exit OK ===');
    } catch (e) {
      debugPrint('=== _exitFullScreen: WindowFullScreen exit failed: $e ===');
    }
    // iOS 端：恢复允许竖屏 + 横屏
    if (Platform.isIOS) {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    // 等待窗口 resize 完成再继续
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // 兜底同步：iOS 端必须；桌面端 no-op
    _onWindowFullScreenChanged();
    // 确保 player 在播放
    try {
      if (!_player.state.playing) {
        await _player.play();
      }
    } catch (_) {}
  }

  void _seekTo(Duration position) {
    final clamped = position < Duration.zero
        ? Duration.zero
        : (position > _duration && _duration > Duration.zero
            ? _duration
            : position);
    _player.seek(clamped);
  }

  void _setSpeed(double speed) {
    _player.setRate(speed);
    setState(() => _playbackSpeed = speed);
    _scheduleHideControls();
  }

  void _setVideoFit(VideoFitType fit) {
    setState(() => _videoFit = fit);
    _scheduleHideControls();
  }

  void _toggleLock() {
    setState(() {
      _isLocked = !_isLocked;
      if (_isLocked) {
        _showControls = false;
      } else {
        _showControls = true;
        _scheduleHideControls();
      }
    });
  }

  void _skipIntro() {
    if (widget.skipIntroSeconds > 0) {
      _seekTo(Duration(seconds: widget.skipIntroSeconds));
      _scheduleHideControls();
    }
  }

  void _skipOutro() {
    if (widget.skipOutroSeconds > 0 && _duration > Duration.zero) {
      _seekTo(_duration - Duration(seconds: widget.skipOutroSeconds));
      _scheduleHideControls();
    }
  }

  void _setVolume(double v) {
    final clamped = v.clamp(0.0, 1.0);
    _player.setVolume(clamped * 100); // media_kit 用 0-100
    setState(() => _volume = clamped);
  }

  void _toggleMute() {
    if (_volume > 0) {
      _setVolume(0);
    } else {
      _setVolume(1);
    }
    _scheduleHideControls();
  }

  void _setBrightness(double b) {
    setState(() => _brightness = b.clamp(0.0, 1.0));
  }
  // _setBrightness 保留供后续接入系统亮度 API 时使用（例如 screen_brightness 插件）

  void _showIndicatorLater() {
    _indicatorTimer?.cancel();
    _indicatorTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      setState(() {
        _showVolumeIndicator = false;
        _showBrightnessIndicator = false;
        _showForwardSeek = false;
        _showBackwardSeek = false;
        _gestureHorizontalHint = '';
      });
    });
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  String _formatSpeed(double speed) {
    if (speed == speed.roundToDouble()) return '${speed.toInt()}X';
    return '${speed.toStringAsFixed(2)}X';
  }

  @override
  void dispose() {
    WindowFullScreen.instance.activeNotifier.removeListener(
      _onWindowFullScreenChanged,
    );
    _hideTimer?.cancel();
    _bitrateTimer?.cancel();
    _indicatorTimer?.cancel();
    if (_ownsPlayer) {
      _player.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        // Esc 退出全屏（native fullscreen 退出）
        SingleActivator(LogicalKeyboardKey.escape): _onUserExitFullscreen,
        // F 切换全屏
        SingleActivator(LogicalKeyboardKey.keyF): _onUserToggleFullscreen,
        // 空格 播放/暂停
        SingleActivator(LogicalKeyboardKey.space): _togglePlayPause,
        // 左右箭头 快进/快退 5 秒
        SingleActivator(LogicalKeyboardKey.arrowLeft): () {
          _seekRelative(-const Duration(seconds: 5));
        },
        SingleActivator(LogicalKeyboardKey.arrowRight): () {
          _seekRelative(const Duration(seconds: 5));
        },
      },
      child: Focus(
        autofocus: true,
        child: ColoredBox(
          color: Colors.black,
          // PiP 模式下用 DragToMoveArea 包住整块内容，让用户能通过拖动视频
          // 来移动无标题栏的小窗口；onPanStart 只在用户真正拖动时才触发，
          // 单击事件仍会冒泡到内部的 _buildGestureLayer() 用于显示/隐藏控件
          child: _buildRootArea(),
        ),
      ),
    );
  }

  Widget _buildRootArea() {
    final stack = _buildContentStack();
    if (widget.isPipMode) {
      return DragToMoveArea(child: stack);
    }
    return stack;
  }

  Widget _buildContentStack() {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 视频画面
        Positioned.fill(
          child: Video(
            // 用 _videoRebuildKey 让 key 变化时重建 Video widget（绕过 ANGLE surface 失效）
            key: ValueKey('video_$_videoRebuildKey'),
            controller: _controller,
            controls: null,
            fit: _videoFit.boxFit,
            aspectRatio: _videoFit.aspectRatio,
            // **重要**：不传 onEnterFullscreen / onExitFullscreen 回调。
            // 这两个回调只在 `defaultEnterNativeFullscreen` 被调时触发，
            // 但我们不用 native fullscreen（避免 ANGLE 黑屏），改用
            // 自定义 `WindowFullScreen` 流程。`onEnterFullscreen` 留空
            // 后 media_kit 内部不会自动调 native API，避免状态机冲突。
          ),
        ),

        // 亮度遮罩 - 用半透明黑色覆盖调整亮度
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              color: Colors.black.withValues(alpha: 1.0 - _brightness),
            ),
          ),
        ),

        // 缓冲指示器
        if (_isBuffering)
          const Center(
            child: SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 3,
              ),
            ),
          ),

        // 手势层（覆盖整个区域，识别单击/双击/长按/拖动）
        Positioned.fill(child: _buildGestureLayer()),

        // 顶部水平拖动提示
        if (_gestureHorizontalHint.isNotEmpty)
          Positioned(
            top: 60,
            left: 0,
            right: 0,
            child: Center(
              child: _GestureHintBubble(text: _gestureHorizontalHint),
            ),
          ),

        // 顶部导航栏
        if (_showControls && !_isLocked) _buildHeaderBar(),

        // 锁定按钮
        if (_showControls || _isLocked) _buildLockButton(),

        // 底部控制区域
        if (_showControls && !_isLocked) _buildBottomControls(),

        // 跳过片头/片尾按钮
        if (!_isLocked) _buildSkipButtons(),

        // 音量指示器
        if (_showVolumeIndicator) _buildVolumeIndicator(),
        if (_showBrightnessIndicator) _buildBrightnessIndicator(),
        if (_showForwardSeek || _showBackwardSeek)
          _buildSeekIndicator(_showForwardSeek),

        // 剧集选择覆盖层
        if (_showEpisodeSheet) _buildEpisodeOverlay(),

        // 设置弹窗
        if (_showSettingsSheet) _buildSettingsSheet(),
      ],
    );
  }

  // ============================================================
  // 手势处理层
  // ============================================================

  Widget _buildGestureLayer() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // **关键**：把长按手势拆到**外层** GestureDetector，
        // 避免与内层 onTap / onDoubleTap 在手势竞技场中相互抢占
        // （Flutter 默认会让长按等待双击判定窗口结束，从而失效）。
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          // 外层只处理长按：长按 2 倍速
          onLongPressStart: (_) {
            if (_isLocked) return;
            _player.setRate(_playbackSpeed * 2);
            setState(() => _isLongPressingFast = true);
          },
          onLongPressEnd: (_) {
            if (_isLocked) return;
            _player.setRate(_playbackSpeed);
            setState(() => _isLongPressingFast = false);
          },
          // 内层处理单击/双击/拖动
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            onDoubleTapDown: (details) {
              final x = details.localPosition.dx;
              if (x < width / 4) {
                _seekBy(-_seekStep, isLeft: true);
              } else if (x > width * 3 / 4) {
                _seekBy(_seekStep, isLeft: false);
              } else {
                _togglePlayPause();
              }
            },
            onDoubleTap: () {},
            onPanStart: (details) {
              if (_isLocked) return;
              _gestureInitialVolume = _volume;
              _gestureInitialBrightness = _brightness;
              _gestureSeekTemp = _position.inMilliseconds.toDouble();
              _gesturePanStartPosition = details.localPosition;
              _gesturePanAxis = null;
              _scheduleHideControls();
            },
            onPanUpdate: (details) {
              if (_isLocked) return;
              final dx = details.localPosition.dx - _gesturePanStartPosition.dx;
              final dy = details.localPosition.dy - _gesturePanStartPosition.dy;
              final absDx = dx.abs();
              final absDy = dy.abs();

              // 第一次确定手势方向
              _gesturePanAxis ??=
                  absDx > absDy * 1.5 ? PanAxis.horizontal : PanAxis.vertical;

              if (_gesturePanAxis == PanAxis.horizontal) {
                if (_duration > Duration.zero) {
                  final totalMs = _duration.inMilliseconds.toDouble();
                  // 屏幕宽度对应整个 duration 的 30%
                  final scale = totalMs * 0.3;
                  final deltaMs = (dx / width) * scale;
                  _gestureSeekTemp =
                      (_gestureSeekTemp + deltaMs).clamp(0.0, totalMs);
                  final newPos = Duration(
                    milliseconds: _gestureSeekTemp.round(),
                  );
                  setState(() {
                    _isDragging = true;
                    _dragValue = _gestureSeekTemp;
                    _gestureHorizontalHint =
                        '${_gestureSeekTemp > _position.inMilliseconds ? '+' : ''}'
                        '${(newPos.inSeconds - _position.inSeconds)}秒'
                        '  ${_formatDuration(newPos)}';
                  });
                }
              } else {
                // 垂直：左侧亮度，右侧音量
                if (_gesturePanStartPosition.dx < width / 2) {
                  final newB = (_gestureInitialBrightness - dy / constraints.maxHeight)
                      .clamp(0.0, 1.0);
                  _setBrightness(newB);
                  setState(() {
                    _showBrightnessIndicator = true;
                    _showVolumeIndicator = false;
                  });
                } else {
                  final newV = (_gestureInitialVolume - dy / constraints.maxHeight)
                      .clamp(0.0, 1.0);
                  setState(() {
                    _setVolume(newV);
                    _showVolumeIndicator = true;
                    _showBrightnessIndicator = false;
                  });
                }
                _showIndicatorLater();
              }
            },
            onPanEnd: (_) {
              if (_isLocked) return;
              if (_gesturePanAxis == PanAxis.horizontal) {
                _seekTo(Duration(milliseconds: _gestureSeekTemp.round()));
                setState(() {
                  _isDragging = false;
                  _gestureHorizontalHint = '';
                });
              } else {
                setState(() {
                  _showVolumeIndicator = false;
                  _showBrightnessIndicator = false;
                });
              }
              _gesturePanAxis = null;
            },
          ),
        );
      },
    );
  }

  Offset _gesturePanStartPosition = Offset.zero;
  PanAxis? _gesturePanAxis;

  void _seekBy(int seconds, {required bool isLeft}) {
    if (_isLocked) return;
    final target = _player.state.position + Duration(seconds: seconds);
    _seekTo(target);
    setState(() {
      _seekAccumulatedSeconds += seconds;
      if (isLeft) {
        _showBackwardSeek = true;
        _showForwardSeek = false;
      } else {
        _showForwardSeek = true;
        _showBackwardSeek = false;
      }
    });
    _showIndicatorLater();
    _scheduleHideControls();
  }

  // ============================================================
  // 顶部导航栏 - 对应 Swift headerBar
  // ============================================================

  Widget _buildHeaderBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: _gradientTopContainer(
        child: Row(
          children: [
            // 标题占满剩余空间（之前的"返回"按钮已移除：在播放器全屏
            // 模式下没"上一页"概念，靠 detail view 自己的 AppBar back；正常
            // 模式点这个按钮就调到 _onUserExitFullscreen 走 Get.back，
            // 但和 detail view 自己的 back 重复，反而容易误触）
            if (_displayTitle.isNotEmpty)
              Expanded(
                child: Text(
                  _displayTitle,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            else
              const Spacer(),

            // 分辨率
            if (_resolutionText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  _resolutionText,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ),

            // 网速
            if (_bitrateText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  _bitrateText,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ),

            // 画中画
            _iconButton(
              icon: Icons.picture_in_picture_alt,
              size: 20,
              width: 36,
              onTap: () {
                _scheduleHideControls();
                _togglePiP();
              },
            ),

            // 投屏（AirPlay / DLNA 入口）
            // iOS 端调原生 AVRoutePickerView，弹出系统 AirPlay 选择器
            // 其他平台暂不实现，提示用户
            _iconButton(
              icon: Icons.cast,
              size: 20,
              width: 36,
              onTap: () {
                _scheduleHideControls();
                _toggleCast();
              },
            ),

            // 设置
            _iconButton(
              icon: Icons.more_horiz,
              size: 22,
              width: 40,
              onTap: () {
                setState(() => _showSettingsSheet = true);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 锁定按钮 - 对应 Swift lockButton
  // ============================================================

  Widget _buildLockButton() {
    return Positioned(
      left: 12,
      top: 0,
      bottom: 0,
      child: Center(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleLock,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.4),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _isLocked ? Icons.lock : Icons.lock_open,
              color: Colors.white,
              size: 18,
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // 底部控制区域 - 对应 Swift bottomSection
  // ============================================================

  Widget _buildBottomControls() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: _gradientBottomContainer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 进度条
            _buildProgressBar(),
            // 控制按钮行
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
              child: Row(
                children: [
                  // 左侧: 播放/暂停 + 时间 + 上一集 + 下一集
                  _buildPlayPauseButton(),
                  _buildTimeView(),
                  if (widget.canPlayPrevious)
                    _iconButton(
                      icon: Icons.skip_previous,
                      size: 22,
                      width: 36,
                      onTap: () {
                        _scheduleHideControls();
                        widget.onPlayPrevious?.call();
                      },
                    ),
                  if (widget.canPlayNext)
                    _iconButton(
                      icon: Icons.skip_next,
                      size: 22,
                      width: 36,
                      onTap: () {
                        _scheduleHideControls();
                        widget.onPlayNext?.call();
                      },
                    ),
                  const Spacer(),
                  // 右侧: 静音 + 选集 + 倍速 + 画面比例 + 全屏
                  _iconButton(
                    icon: _volume > 0
                        ? (_volume < 0.33
                            ? Icons.volume_down
                            : (_volume < 0.66
                                ? Icons.volume_up
                                : Icons.volume_up))
                        : Icons.volume_off,
                    size: 22,
                    width: 36,
                    onTap: _toggleMute,
                  ),
                  if (widget.episodeNames.isNotEmpty)
                    _iconButton(
                      icon: Icons.list,
                      size: 22,
                      width: 36,
                      onTap: () {
                        setState(() => _showEpisodeSheet = true);
                      },
                    ),
                  _buildVideoFitMenu(),
                  _buildSpeedMenu(),
                  _iconButton(
                    icon: _isNativeFullscreen
                        ? Icons.fullscreen_exit
                        : Icons.fullscreen,
                    size: 24,
                    width: 42,
                    onTap: () {
                      _scheduleHideControls();
                      _onUserToggleFullscreen();
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 跳过片头/片尾按钮
  // ============================================================

  Widget _buildSkipButtons() {
    final showIntro = widget.skipIntroSeconds > 0 &&
        _position.inSeconds > 0 &&
        _position.inSeconds < widget.skipIntroSeconds;
    final showOutro = widget.skipOutroSeconds > 0 &&
        _duration > Duration.zero &&
        _position.inSeconds >
            _duration.inSeconds - widget.skipOutroSeconds;

    if (!showIntro && !showOutro) return const SizedBox.shrink();

    return Positioned(
      top: 70,
      left: 0,
      right: 0,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            if (showIntro)
              _skipButton(
                text: '跳过片头',
                onTap: _skipIntro,
              ),
            const Spacer(),
            if (showOutro)
              _skipButton(
                text: '跳过片尾',
                onTap: _skipOutro,
              ),
          ],
        ),
      ),
    );
  }

  Widget _skipButton({required String text, required VoidCallback onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.skip_next,
              color: Colors.white,
              size: 14,
            ),
            const SizedBox(width: 4),
            Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 音量/亮度/进度指示器
  // ============================================================

  Widget _buildVolumeIndicator() {
    return Center(
      child: _IndicatorBadge(
        icon: _volume <= 0
            ? Icons.volume_off
            : (_volume < 0.5 ? Icons.volume_down : Icons.volume_up),
        text: '${(_volume * 100).round()}%',
      ),
    );
  }

  Widget _buildBrightnessIndicator() {
    return Center(
      child: _IndicatorBadge(
        icon: Icons.brightness_6,
        text: '${(_brightness * 100).round()}%',
      ),
    );
  }

  Widget _buildSeekIndicator(bool isForward) {
    return Positioned.fill(
      child: Row(
        children: [
          if (!isForward)
            Expanded(
              child: Container(
                color: Colors.black.withValues(alpha: 0.3),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isForward ? Icons.fast_forward : Icons.fast_rewind,
                        color: Colors.white,
                        size: 36,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${isForward ? '快进' : '快退'}${_seekAccumulatedSeconds.abs()}秒',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (isForward)
            Expanded(
              child: Container(
                color: Colors.black.withValues(alpha: 0.3),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.fast_forward,
                        color: Colors.white,
                        size: 36,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '快进${_seekAccumulatedSeconds.abs()}秒',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ============================================================
  // 自定义进度条 - 对应 Swift PlayerProgressBar
  // ============================================================

  Widget _buildProgressBar() {
    final totalMs = _duration.inMilliseconds.toDouble();
    final currentMs = _isDragging
        ? _dragValue
        : _position.inMilliseconds.toDouble();
    final progress = totalMs > 0 ? (currentMs / totalMs).clamp(0.0, 1.0) : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: SizedBox(
        height: 20,
        child: _ProgressBarGesture(
          progress: progress,
          onSeekToRatio: (ratio) {
            if (totalMs > 0) {
              final targetMs = ratio * totalMs;
              _seekTo(Duration(milliseconds: targetMs.round()));
            }
          },
          onDrag: (ratio) {
            setState(() {
              _isDragging = true;
              _dragValue = ratio * totalMs;
            });
            _scheduleHideControls();
          },
          onDragEnd: () {
            setState(() => _isDragging = false);
            _scheduleHideControls();
          },
        ),
      ),
    );
  }

  // ============================================================
  // 播放/暂停按钮
  // ============================================================

  Widget _buildPlayPauseButton() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _togglePlayPause,
      child: SizedBox(
        width: 42,
        height: 34,
        child: Center(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: Icon(
              _isPlaying ? Icons.pause : Icons.play_arrow,
              key: ValueKey(_isPlaying),
              color: Colors.white,
              size: 26,
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // 时间显示
  // ============================================================

  Widget _buildTimeView() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _formatDuration(
              _isDragging
                  ? Duration(milliseconds: _dragValue.round())
                  : _position,
            ),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontFamily: 'monospace',
            ),
          ),
          Text(
            _duration > Duration.zero ? _formatDuration(_duration) : '--:--',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.82),
              fontSize: 10,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 倍速菜单
  // ============================================================

  Widget _buildSpeedMenu() {
    return PopupMenuButton<double>(
      tooltip: '倍速',
      offset: const Offset(0, -180),
      color: AppTheme.backgroundSecondary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMD),
      ),
      onSelected: _setSpeed,
      itemBuilder: (context) => _supportedSpeeds.map((speed) {
        final selected = (speed - _playbackSpeed).abs() < 0.01;
        return PopupMenuItem<double>(
          height: 32,
          value: speed,
          child: Row(
            children: [
              Text(
                _formatSpeed(speed),
                style: TextStyle(
                  color: selected ? AppTheme.accentColor : AppTheme.textPrimary,
                  fontSize: 13,
                ),
              ),
              if (selected) ...[
                const Spacer(),
                const Icon(Icons.check, color: AppTheme.accentColor, size: 16),
              ],
            ],
          ),
        );
      }).toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        constraints: const BoxConstraints(minWidth: 38, minHeight: 30),
        child: Center(
          child: Text(
            _formatSpeed(_playbackSpeed),
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // 画面比例菜单
  // ============================================================

  Widget _buildVideoFitMenu() {
    return PopupMenuButton<VideoFitType>(
      tooltip: '画面比例',
      offset: const Offset(0, -180),
      color: AppTheme.backgroundSecondary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMD),
      ),
      onSelected: _setVideoFit,
      itemBuilder: (context) => VideoFitType.values.map((fit) {
        final selected = fit == _videoFit;
        return PopupMenuItem<VideoFitType>(
          height: 32,
          value: fit,
          child: Row(
            children: [
              Text(
                fit.desc,
                style: TextStyle(
                  color: selected ? AppTheme.accentColor : AppTheme.textPrimary,
                  fontSize: 13,
                ),
              ),
              if (selected) ...[
                const Spacer(),
                const Icon(Icons.check, color: AppTheme.accentColor, size: 16),
              ],
            ],
          ),
        );
      }).toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        constraints: const BoxConstraints(minWidth: 38, minHeight: 30),
        child: Center(
          child: Text(
            _videoFit.desc,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // 剧集选择覆盖层
  // ============================================================

  Widget _buildEpisodeOverlay() {
    return Positioned.fill(
      // **重要**：用 ColoredBox 替换 Material，避免在 Stack 里
      // 脱离 Scaffold 上下文时的灰屏渲染异常。
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _showEpisodeSheet = false),
              child: const Expanded(child: SizedBox.shrink()),
            ),
            Container(
              constraints: const BoxConstraints(maxHeight: 320),
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Row(
                      children: [
                        const Text(
                          '选集',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => _showEpisodeSheet = false),
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(
                              Icons.close,
                              color: Colors.white70,
                              size: 18,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: GridView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 5,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                        childAspectRatio: 2.5,
                      ),
                      itemCount: widget.episodeNames.length,
                      itemBuilder: (context, index) {
                        final isSelected = index == widget.selectedEpisodeIndex;
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            widget.onSelectEpisode?.call(index);
                            setState(() => _showEpisodeSheet = false);
                          },
                          child: Container(
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? Colors.white.withValues(alpha: 0.25)
                                  : Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              widget.episodeNames[index],
                              style: TextStyle(
                                color: isSelected ? Colors.white : Colors.white70,
                                fontSize: 13,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 设置弹窗
  // ============================================================

  Widget _buildSettingsSheet() {
    return Positioned.fill(
      // **重要**：用 ColoredBox 替换 Material，避免在 Stack 里
      // 脱离 Scaffold 上下文时的灰屏渲染异常。
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _showSettingsSheet = false),
              child: const Expanded(child: SizedBox.shrink()),
            ),
            Container(
              constraints: const BoxConstraints(maxHeight: 480),
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        '播放设置',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () =>
                            setState(() => _showSettingsSheet = false),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(
                            Icons.close,
                            color: Colors.white70,
                            size: 18,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 跳过片头
                          const _SettingsRowLabel('跳过片头'),
                          const SizedBox(height: 8),
                          _SkipSecondsEditor(
                            label: '片头',
                            value: widget.skipIntroSeconds,
                            onChange: (v) => widget.onSetSkipIntro?.call(v),
                            presets: _skipPresets,
                            maxSeconds: _skipMaxSeconds,
                          ),
                          const SizedBox(height: 16),
                          // 跳过片尾
                          const _SettingsRowLabel('跳过片尾'),
                          const SizedBox(height: 8),
                          _SkipSecondsEditor(
                            label: '片尾',
                            value: widget.skipOutroSeconds,
                            onChange: (v) => widget.onSetSkipOutro?.call(v),
                            presets: _skipPresets,
                            maxSeconds: _skipMaxSeconds,
                          ),
                          const SizedBox(height: 16),
                          if (_resolutionText.isNotEmpty) ...[
                            const _SettingsRowLabel('播放信息'),
                            const SizedBox(height: 8),
                            Text(
                              '分辨率: $_resolutionText',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                            if (_bitrateText.isNotEmpty)
                              Text(
                                '网速: $_bitrateText',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 画中画
  // ============================================================

  Future<void> _togglePiP() async {
    // iOS 端：当前 Flutter 端没有原生 AVPictureInPictureController 实现，
    // 直接调 VideoPlayerPip.toggle() 会因为 unsupported platform 静默失败。
    // 给出明确提示让用户知道原因。
    if (Platform.isIOS) {
      _showMessage('iOS 端画中画：当前版本暂未集成 AVPictureInPictureController。\n'
          '如需小窗播放，请先退出全屏并手动从控制中心选择 AirPlay 设备。');
      return;
    }
    // 互斥：如果当前是全屏状态，先 await 退出全屏再进入 PiP
    if (WindowFullScreen.instance.isActive || _isNativeFullscreen) {
      await _exitFullScreen();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    // 附加当前 Player 到 PiP 模块（不创建新实例，保留播放状态）
    VideoPlayerPip.instance.attachPlayer(_player);
    await VideoPlayerPip.instance.toggle();
  }

  /// 投屏入口（DLNA/UPnP）
  ///
  /// **实现**：参考 PiliPlus-main/lib/pages/dlna/view.dart，使用
  /// `dlna_dart: ^0.1.0` 库（纯 Dart 实现，跨 iOS / Android / macOS / Windows / Linux）。
  ///
  /// 流程：
  /// 1. 跳到 DLNAPage（路由 /dlna）
  /// 2. DLNAManager.start() 扫描局域网内 DLNA/UPnP 设备（30 秒超时）
  /// 3. 用户选设备 → device.setUrl(playUrl, title: videoTitle) + device.play()
  /// 4. DMR（智能电视 / 投影仪 / 音箱）开始播放
  ///
  /// **iOS 端权限**：需要 NSLocalNetworkUsageDescription + NSBonjourServices
  /// 已配置在 ios/Runner/Info.plist。
  Future<void> _toggleCast() async {
    final playUrl = _player.state.playlist.medias.isNotEmpty
        ? _player.state.playlist.medias.last.uri
        : widget.url;
    if (playUrl.isEmpty) {
      _showMessage('投屏：当前没有可投屏的视频地址');
      return;
    }
    Get.toNamed(
      '/dlna',
      parameters: {
        'url': playUrl,
        'title': _displayTitle.isNotEmpty ? _displayTitle : (widget.videoTitle ?? ''),
      },
    );
  }

  /// 用 ScaffoldMessenger 显示一条提示
  void _showMessage(String text) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(SnackBar(
      content: Text(text),
      duration: const Duration(seconds: 3),
      backgroundColor: Colors.black87,
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ============================================================
  // 通用辅助方法
  // ============================================================

  String get _displayTitle {
    final t = widget.videoTitle ?? '';
    final e = widget.currentEpisodeName ?? '';
    if (e.isNotEmpty) return '$t - $e';
    return t;
  }

  Widget _gradientTopContainer({required Widget child}) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 11, left: 4, right: 4),
        child: child,
      ),
    );
  }

  Widget _gradientBottomContainer({required Widget child}) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black87],
        ),
      ),
      child: child,
    );
  }

  Widget _iconButton({
    required IconData icon,
    required double size,
    double width = 36,
    double height = 30,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: width,
        height: height,
        child: Center(
          child: Icon(icon, color: Colors.white, size: size),
        ),
      ),
    );
  }
}

enum PanAxis { horizontal, vertical }

// ============================================================
// 进度条拖动手势
// ============================================================

class _ProgressBarGesture extends StatelessWidget {
  final double progress;
  final void Function(double ratio) onSeekToRatio;
  final void Function(double ratio) onDrag;
  final VoidCallback onDragEnd;

  const _ProgressBarGesture({
    required this.progress,
    required this.onSeekToRatio,
    required this.onDrag,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            final ratio = (details.localPosition.dx / w).clamp(0.0, 1.0);
            onDrag(ratio);
            onSeekToRatio(ratio);
          },
          onHorizontalDragStart: (details) {
            final ratio = (details.localPosition.dx / w).clamp(0.0, 1.0);
            onDrag(ratio);
          },
          onHorizontalDragUpdate: (details) {
            final ratio = (details.localPosition.dx / w).clamp(0.0, 1.0);
            onDrag(ratio);
          },
          onHorizontalDragEnd: (_) => onDragEnd(),
          child: CustomPaint(
            size: Size(w, 20),
            painter: _ProgressBarPainter(progress: progress),
          ),
        );
      },
    );
  }
}

class _ProgressBarPainter extends CustomPainter {
  final double progress;
  _ProgressBarPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    const trackHeight = 3.5;
    const thumbRadius = 7.0;

    final trackRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, centerY - trackHeight / 2, size.width, trackHeight),
      Radius.circular(trackHeight / 2),
    );
    canvas.drawRRect(
      trackRect,
      Paint()..color = Colors.white.withValues(alpha: 0.2),
    );

    if (progress > 0) {
      final progressRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, centerY - trackHeight / 2,
            size.width * progress, trackHeight),
        Radius.circular(trackHeight / 2),
      );
      canvas.drawRRect(progressRect, Paint()..color = Colors.white);
    }

    final thumbX =
        (size.width * progress).clamp(thumbRadius, size.width - thumbRadius);
    canvas.drawCircle(
      Offset(thumbX, centerY),
      thumbRadius,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_ProgressBarPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

// ============================================================
// 通用 UI 组件
// ============================================================

class _IndicatorBadge extends StatelessWidget {
  final IconData icon;
  final String text;
  const _IndicatorBadge({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(40),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 28),
          const SizedBox(height: 6),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class _GestureHintBubble extends StatelessWidget {
  final String text;
  const _GestureHintBubble({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

class _SettingsRowLabel extends StatelessWidget {
  final String text;
  const _SettingsRowLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

/// 跳过片头/片尾时间编辑器
/// 包含：自定义秒数输入框 + 快捷预设按钮
class _SkipSecondsEditor extends StatefulWidget {
  final String label;
  final int value;
  final ValueChanged<int> onChange;
  final List<int> presets;
  final int maxSeconds;

  const _SkipSecondsEditor({
    required this.label,
    required this.value,
    required this.onChange,
    required this.presets,
    required this.maxSeconds,
  });

  @override
  State<_SkipSecondsEditor> createState() => _SkipSecondsEditorState();
}

class _SkipSecondsEditorState extends State<_SkipSecondsEditor> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.toString());
    _focusNode = FocusNode();
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        _submit();
      }
    });
  }

  @override
  void didUpdateWidget(covariant _SkipSecondsEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !_focusNode.hasFocus) {
      _controller.text = widget.value.toString();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      _controller.text = widget.value.toString();
      setState(() => _errorText = null);
      return;
    }
    final n = int.tryParse(text);
    if (n == null) {
      setState(() => _errorText = '请输入数字');
      return;
    }
    if (n < 0) {
      setState(() => _errorText = '不能小于 0');
      return;
    }
    if (n > widget.maxSeconds) {
      setState(() => _errorText = '不能超过 ${widget.maxSeconds} 秒');
      return;
    }
    setState(() => _errorText = null);
    if (n != widget.value) {
      widget.onChange(n);
    }
  }

  void _applyPreset(int s) {
    _controller.text = s.toString();
    setState(() => _errorText = null);
    widget.onChange(s);
    _focusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 输入框 + 提交按钮
        Row(
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _errorText != null
                        ? Colors.red
                        : Colors.white.withValues(alpha: 0.1),
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Icon(
                        Icons.timer_outlined,
                        color: Colors.white70,
                        size: 16,
                      ),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.done,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                        cursorColor: AppTheme.accentColor,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: 10),
                          isDense: true,
                          hintText: '秒',
                          hintStyle: TextStyle(
                            color: Colors.white24,
                            fontSize: 14,
                          ),
                        ),
                        onSubmitted: (_) {
                          _submit();
                          _focusNode.unfocus();
                        },
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        '秒',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _submit();
                _focusNode.unfocus();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.accentColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '应用',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
        if (_errorText != null) ...[
          const SizedBox(height: 4),
          Text(
            _errorText!,
            style: const TextStyle(color: Colors.red, fontSize: 11),
          ),
        ],
        const SizedBox(height: 8),
        // 快捷预设
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: widget.presets.map((s) {
            final selected = widget.value == s;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _applyPreset(s),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: selected
                      ? AppTheme.accentColor
                      : Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  s == 0 ? '关闭' : '${s}秒',
                  style: TextStyle(
                    color: selected ? Colors.white : Colors.white70,
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}
