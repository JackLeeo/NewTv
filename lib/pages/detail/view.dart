import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart' hide Video;
import '../../common/theme.dart';
import '../../models/movie.dart';
import '../../models/vod_info.dart';
import '../../models/cache_store.dart';
import '../../services/background_service.dart';
import '../../services/player_fullscreen_controller.dart';
import '../../widgets/common_widgets.dart';
import '../../widgets/video_player.dart';
import '../../widgets/video_player_pip.dart';
import '../../widgets/window_fullscreen.dart';
import 'controller.dart';
import 'episode_list.dart';

/// 详情页 - 对应 Swift DetailView
class DetailPage extends StatefulWidget {
  DetailPage({super.key});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  final _controller = Get.put(DetailController());
  bool _isDescriptionExpanded = false;
  double _lastPersistedProgress = 0;

  /// 持有 Player 实例，全屏/普通模式之间复用同一实例，避免状态丢失
  Player? _player;
  /// 持有 VideoController 实例，与上面 _player 配套使用，跨全屏/普通模式共享，
  /// 保证 ANGLE surface / texture 通道在 OS 全屏切换时不被重建。
  VideoController? _videoController;
  String? _lastPlayerUrl;
  String? _lastPlayerHeadersKey;

  /// VideoPlayerWidget 状态变化回调（mpv native fullscreen 状态变化时）
  /// true=进入 native 全屏，false=退出 native 全屏
  void _onFullScreenChanged(bool isFull) {
    if (!mounted) return;
    _controller.isFullScreen.value = isFull;
    // **2026-07-09**: 同步全局全屏状态, 让 app.dart 根 Scaffold 的
    // 底栏(首页/直播/历史/收藏/设置) 在全屏时隐藏
    if (isFull) {
      PlayerFullscreenController.instance.enter('detail');
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    } else {
      PlayerFullscreenController.instance.exit('detail');
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  @override
  void initState() {
    super.initState();
    _loadDetailIfNeeded();
    // 监听 PiP 状态变化，确保退出 PiP 时退出全屏（互斥）
    VideoPlayerPip.instance.activeNotifier.addListener(_onPipChanged);
    // 监听 WindowFullScreen 状态变化：作为冗余同步通道，
    // 保证 WindowFullScreen.toggle 后 isFullScreen Rx 一定被同步
    WindowFullScreen.instance.activeNotifier.addListener(_onFullScreenActiveChanged);
  }

  void _loadDetailIfNeeded() {
    final video = Get.arguments;
    if (video != null && video is Video && _controller.vodInfo.value == null) {
      _controller.loadDetail(video).then((_) {
        _restorePlaybackFromHistory();
        _refreshCollectState();
      });
    }
  }

  void _onPipChanged() {
    if (mounted) setState(() {});
  }

  /// 冗余同步通道：WindowFullScreen 状态变化时同步 detail view 的 Rx
  /// （与 onFullScreenChanged 回调功能相同，作为兜底）
  void _onFullScreenActiveChanged() {
    if (!mounted) return;
    final isFull = WindowFullScreen.instance.isActive;
    if (_controller.isFullScreen.value != isFull) {
      _controller.isFullScreen.value = isFull;
    }
  }

  @override
  void dispose() {
    VideoPlayerPip.instance.activeNotifier.removeListener(_onPipChanged);
    WindowFullScreen.instance.activeNotifier.removeListener(_onFullScreenActiveChanged);
    // 退出页面时关闭 PiP，恢复窗口
    if (VideoPlayerPip.instance.isActive) {
      VideoPlayerPip.instance.exit();
    }
    // 退出页面时退出全屏，恢复窗口
    if (WindowFullScreen.instance.isActive) {
      WindowFullScreen.instance.exit();
    }
    VideoPlayerPip.instance.detachPlayer();
    _player?.dispose();
    _player = null;
    _videoController = null;
    super.dispose();
  }

  /// 确保 player 已创建并打开当前 url
  /// 同一 url+headers 不重复创建
  ///
  /// **startPosition 续播**：传 `Duration` 给 `Media.start` 参数，
  /// 让 libmpv 在 player open 时**直接**从续播位置开始解码，
  /// 避免 "先从 0 播几秒再回退" 的现象。对应 Swift 的
  /// `mediaPlayerStateChanged → state=.playing → applyPendingSeekIfNeeded`
  /// 模式，但 libmpv 端做更彻底 (根本不会经过 0 位置)。
  /// - 传 null / 0 → 从 0 开始（冷启动 / 切换集数）
  /// - 传 > 0 → 从该秒数开始（续播）
  void _ensurePlayer(
    String url,
    Map<String, String> headers, {
    double? startPosition,
  }) {
    final headersKey = headers.entries
        .map((e) => '${e.key}=${e.value}')
        .join('&');
    if (_player != null &&
        _lastPlayerUrl == url &&
        _lastPlayerHeadersKey == headersKey) {
      return;
    }
    _player?.dispose();
    _player = Player(configuration: const PlayerConfiguration(title: 'TVBox'));
    // 同步创建 VideoController，确保 player 与 controller 一一对应
    _videoController = VideoController(_player!);
    _lastPlayerUrl = url;
    _lastPlayerHeadersKey = headersKey;
    final start = (startPosition != null && startPosition > 0)
        ? Duration(seconds: startPosition.toInt())
        : null;
    _player!.open(Media(url, httpHeaders: headers, start: start));
  }

  @override
  Widget build(BuildContext context) {
    // 关键：isFull / isPip 必须在 Obx 内读取，Rx 变化才能触发 rebuild
    // 否则在 _exitFullScreenRoute 里 _controller.isFullScreen.value = false
    // 不会触发顶层 build，immersive 永远停留在 true（AppBar 永远隐藏）
    return Obx(() {
      final isFull = _controller.isFullScreen.value;
      final isPip = VideoPlayerPip.instance.activeNotifier.value;
      final immersive = isFull || isPip;

      return Scaffold(
        appBar: immersive
            ? null
            : AppBar(
                leading: IconButton(
                  icon: const Icon(Icons.chevron_left,
                      color: AppTheme.textPrimary, size: 28),
                  onPressed: () => Get.back(),
                ),
                // AppBar 半透明, 让 BackgroundService 全局背景层透出
                backgroundColor: AppTheme.backgroundCard,
                elevation: 0,
              ),
        body: immersive
            // 全屏/沉浸: 视频黑底, 不需要背景层
            ? Container(
                color: Colors.black,
                child: _buildBody(),
              )
            // 普通模式: Stack 底 = BackgroundService 全局背景, 顶 = body 内容
            // body 透明让背景层透出, 内容里的 AppCard 等用半透明色
            : Stack(
                children: [
                  Positioned.fill(
                    child: BackgroundService.instance
                        .buildBackground(overlayAlpha: 0.3),
                  ),
                  // 不传 immersive, 让 _buildBody 自己在 Obx 内读取 isFull/isPip
                  // 否则外层 rebuild 时内层 Obx 用的是闭包捕获的旧值
                  _buildBody(),
                ],
              ),
      );
    });
  }

  /// build 的 body 部分（视频区域 + 信息 + 选集 + 简介）
  /// isFull / isPip 必须在本方法内自己读 Rx，闭包捕获的旧值会让全屏态卡死
  Widget _buildBody() {
    return Obx(() {
      // 关键：这里再读一次 isFullScreen / activeNotifier，让本 Obx 监听它们
      // 外层 Obx rebuild 时本 Obx 也会跟着 rebuild
      final isFull = _controller.isFullScreen.value;
      final isPip = VideoPlayerPip.instance.activeNotifier.value;
      // 兜底：如果 Rx 与 WindowFullScreen 状态不一致，以 WindowFullScreen 为准
      final actualFull = isFull || WindowFullScreen.instance.isActive;
      final immersive = actualFull || isPip;

      if (_controller.isLoading.value && _controller.vodInfo.value == null) {
        return const AppLoading();
      }

      if (_controller.errorMessage.value != null &&
          _controller.vodInfo.value == null) {
        return AppError(
          message: _controller.errorMessage.value!,
          onRetry: () {
            final video = Get.arguments;
            if (video != null && video is Video) {
              _controller.loadDetail(video);
            }
          },
        );
      }

      final info = _controller.vodInfo.value;
      if (info == null) return const SizedBox.shrink();

      // 全屏 / PiP 模式：只显示视频（视频始终在 tree 中同一位置）
      if (immersive) {
        return _buildPlayerArea();
      }

      // 正常模式：视频 + 视频信息 + 选集 + 简介
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. 播放器 - 对应 Swift PlayerView
            if (_controller.isPlaying.value) _buildPlayerArea(),

            // 2. 视频信息区 - 对应 Swift videoInfoSection
            _buildVideoInfo(),

            // 3. 线路选择 - 对应 Swift flagSelector
            if (_controller.flags.length > 1) _buildFlagSelector(),

            // 4. 清晰度选择 - 对应 Swift qualitySelector
            if (_controller.hasQualityChoices) _buildQualitySelector(),

            // 5. 选集播放 - 对应 Swift episodeSection
            if (_controller.currentEpisodes.isNotEmpty)
              _buildEpisodeList(),

            // 6. 影片简介 - 对应 Swift descriptionSection
            if (info.des.isNotEmpty) _buildDescription(),

            // 底部间距 - 对应 Swift .padding(.bottom, 80)
            const SizedBox(height: 80),
          ],
        ),
      );
    });
  }

  // MARK: - 播放器

  /// 播放器区域 - 始终在 tree 中同一位置，避免 VideoPlayerWidget 被重建
  /// 16:9 容器内放视频；如果父容器充满（immersive 模式），则视频也充满父容器
  /// 全屏切换由 detail view 自己管理的 Overlay + EnterNativeFullscreen/ExitNativeFullscreen
  /// 通道处理（见 _enterFullScreenRoute / _exitFullScreenRoute）。
  /// PiP 互斥由 widget 内部的 _togglePiP / _onUserToggleFullscreen 处理。

  Widget _buildPlayerArea() {
    // 关键：isFull/isPip/playUrl 都在同一个 Obx 内读取，
    // 任何一个变化都会触发 rebuild，_buildPlayerWidget 内能拿到最新值
    return Obx(() {
      final isFull = _controller.isFullScreen.value;
      final isPip = VideoPlayerPip.instance.activeNotifier.value;
      final url = _controller.playUrl.value;
      if (url != null && url.isNotEmpty) {
        return _buildPlayerWidget(isFull: isFull, isPip: isPip);
      } else {
        // 正在播放但 URL 尚未就绪
        return AspectRatio(
          aspectRatio: 16 / 9,
          child: Container(
            color: Colors.black,
            child: const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          ),
        );
      }
    });
  }

  /// 创建并返回播放器 widget
  /// 视频组件本身不感知全屏/普通模式，全屏由 VideoState 内部处理
  /// isFull/isPip 必须由 _buildPlayerArea 在 Obx 内传入，
  /// 否则 Rx 变化时这里还是用闭包捕获的旧值，导致全屏态无法退出
  Widget _buildPlayerWidget({required bool isFull, required bool isPip}) {
    final url = _controller.playUrl.value!;
    final headers = _controller.playHeaders.isNotEmpty
        ? Map<String, String>.from(_controller.playHeaders)
        : const <String, String>{};
    // 把续播位置透传给 _ensurePlayer, 让 libmpv 通过 Media.start 参数
    // 直接从续播位置开始解码, 避免 "先从 0 播几秒再回退" 的现象
    _ensurePlayer(url, headers, startPosition: _controller.resumeSeconds.value);

    final info = _controller.vodInfo.value;
    final episode = info?.currentEpisode;
    final widget = VideoPlayerWidget(
      key: const ValueKey('detail_player'),
      player: _player,
      controller: _videoController, // 跨全屏/普通模式共享同一个 controller
      url: url,
      headers: headers.isEmpty ? null : headers,
      resumeSeconds: _controller.resumeSeconds.value,
      videoTitle: info?.name,
      currentEpisodeName: episode?.name,
      episodeNames: _controller.currentEpisodes
          .map((e) => e.name)
          .toList(),
      selectedEpisodeIndex: _controller.selectedEpisodeIndex.value,
      canPlayNext: _controller.selectedEpisodeIndex.value <
          _controller.currentEpisodes.length - 1,
      canPlayPrevious: _controller.selectedEpisodeIndex.value > 0,
      isPipMode: isPip,
      skipIntroSeconds: _controller.skipIntroSeconds.value,
      skipOutroSeconds: _controller.skipOutroSeconds.value,
      onPlayNext: () => _playNextEpisode(),
      onPlayPrevious: () => _playPreviousEpisode(),
      onSelectEpisode: (index) {
        _controller.selectEpisode(index);
        _saveHistoryForCurrentEpisode();
      },
      onPositionChanged: (pos) =>
          _handlePlaybackProgress(pos.inSeconds.toDouble()),
      onEnded: () => _playNextEpisode(),
      // native fullscreen 状态变化回调：同步 detail view 的 immersive 模式
      onFullScreenChanged: _onFullScreenChanged,
      onBack: () {
        // 处于 PiP 模式时，返回键先退出 PiP 恢复原窗口
        if (VideoPlayerPip.instance.isActive) {
          VideoPlayerPip.instance.exit();
          return;
        }
        Get.back();
      },
      onSetSkipIntro: (s) => _controller.setSkipIntroSeconds(s),
      onSetSkipOutro: (s) => _controller.setSkipOutroSeconds(s),
    );

    // immersive 模式（native 全屏 / PiP）：视频填满父容器
    // 正常模式：16:9 容器
    if (isFull || isPip) {
      return SizedBox.expand(child: widget);
    }
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: widget,
    );
  }

  // MARK: - 视频信息区

  /// 视频信息区 - 对应 Swift videoInfoSection (AppCard)
  Widget _buildVideoInfo() {
    final info = _controller.vodInfo.value;
    if (info == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingLG, AppTheme.spacingLG, AppTheme.spacingLG, 0),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 名称 - 对应 Swift fontTitle2
            Text(
              info.name,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontTitle2,
                fontWeight: FontWeight.bold,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppTheme.spacingMD),

            // 元数据药丸 - 对应 Swift metadataFlow
            _buildMetadataFlow(info),
            const SizedBox(height: AppTheme.spacingMD),

            // 播放 + 收藏按钮 - 对应 Swift playButton + collectButton
            Row(
              children: [
                Expanded(child: _buildPlayButton()),
                const SizedBox(width: AppTheme.spacingMD),
                Expanded(child: _buildCollectButton()),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 元数据流 - 对应 Swift metadataFlow
  Widget _buildMetadataFlow(VodInfo info) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 药丸行 - 对应 Swift HStack(metadataPill)
        Wrap(
          spacing: AppTheme.spacingSM,
          runSpacing: AppTheme.spacingXS,
          children: [
            if (info.year.isNotEmpty) MetadataPill(text: info.year),
            if (info.typeName.isNotEmpty) MetadataPill(text: info.typeName),
            if (info.area.isNotEmpty) MetadataPill(text: info.area),
          ],
        ),
        const SizedBox(height: AppTheme.spacingSM),

        // 导演 - 对应 Swift director row
        if (info.director.isNotEmpty) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(
                width: 36,
                child: Text(
                  '导演',
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontCaption,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  info.director,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: AppTheme.fontCaption,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.spacingSM),
        ],

        // 演员 - 对应 Swift actor row
        if (info.actor.isNotEmpty) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(
                width: 36,
                child: Text(
                  '演员',
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontCaption,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  info.actor,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: AppTheme.fontCaption,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// 播放按钮 - 对应 Swift playButton (仅未播放且有 vodInfo 时显示)
  Widget _buildPlayButton() {
    return Obx(() {
      if (_controller.isPlaying.value || _controller.vodInfo.value == null) {
        return const SizedBox.shrink();
      }
      return GestureDetector(
        onTap: () {
          _controller.selectEpisode(0);
          _saveHistoryForCurrentEpisode();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: AppTheme.spacingMD),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF5CB67B), Color(0xFF7DCEA0)],
            ),
            borderRadius: BorderRadius.circular(AppTheme.radiusMD),
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.play_arrow, color: Colors.white, size: 18),
              SizedBox(width: AppTheme.spacingSM),
              Text(
                '播放',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  /// 收藏按钮 - 对应 Swift collectButton (gradient when collected, border when not)
  Widget _buildCollectButton() {
    return Obx(() {
      final info = _controller.vodInfo.value;
      if (info == null) return const SizedBox.shrink();
      final isCollected = CacheStore.instance.isCollected(info.id, info.sourceKey);

      return GestureDetector(
        onTap: () async {
          if (isCollected) {
            await CacheStore.instance.removeCollect(info.id, info.sourceKey);
          } else {
            await CacheStore.instance.addCollect(info.toVideo());
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: AppTheme.spacingMD),
          decoration: BoxDecoration(
            gradient: isCollected
                ? const LinearGradient(
                    colors: [Color(0xFF5CB67B), Color(0xFF7DCEA0)],
                  )
                : null,
            color: isCollected ? null : AppTheme.backgroundTertiary,
            borderRadius: BorderRadius.circular(AppTheme.radiusMD),
            border: isCollected
                ? null
                : Border.all(color: AppTheme.borderMedium, width: 1),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isCollected ? Icons.favorite : Icons.favorite_border,
                size: 18,
                color: isCollected ? Colors.white : AppTheme.textSecondary,
              ),
              const SizedBox(width: AppTheme.spacingXS),
              Text(
                isCollected ? '已收藏' : '收藏',
                style: TextStyle(
                  color: isCollected ? Colors.white : AppTheme.textSecondary,
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  // MARK: - 线路选择

  /// 线路选择 - 对应 Swift flagSelector (AppCard)
  Widget _buildFlagSelector() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingLG, AppTheme.spacingMD, AppTheme.spacingLG, 0),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: '播放线路', icon: Icons.settings_input_antenna),
            const SizedBox(height: AppTheme.spacingSM),
            Obx(() => SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _controller.flags.map((flag) {
                      final isSelected =
                          _controller.selectedFlag.value == flag;
                      return Padding(
                        padding: const EdgeInsets.only(right: AppTheme.spacingSM),
                        child: _PillChip(
                          title: flag,
                          isSelected: isSelected,
                          onTap: () {
                            _controller.selectFlag(flag);
                            if (_controller.isPlaying.value) {
                              _saveHistoryForCurrentEpisode();
                            }
                          },
                        ),
                      );
                    }).toList(),
                  ),
                )),
          ],
        ),
      ),
    );
  }

  // MARK: - 清晰度选择

  /// 清晰度选择 - 对应 Swift qualitySelector (AppCard)
  Widget _buildQualitySelector() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingLG, AppTheme.spacingMD, AppTheme.spacingLG, 0),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: '视频清晰度', icon: Icons.auto_awesome),
            const SizedBox(height: AppTheme.spacingSM),
            Obx(() => SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children:
                        _controller.qualityOptions.map((option) {
                      final isSelected =
                          _controller.selectedQualityId.value == option.id;
                      return Padding(
                        padding: const EdgeInsets.only(right: AppTheme.spacingSM),
                        child: _PillChip(
                          title: option.name,
                          isSelected: isSelected,
                          onTap: () {
                            _controller.selectQuality(option);
                            if (_controller.isPlaying.value) {
                              _saveHistoryForCurrentEpisode();
                            }
                          },
                        ),
                      );
                    }).toList(),
                  ),
                )),
          ],
        ),
      ),
    );
  }

  // MARK: - 选集播放

  /// 选集播放 - 对应 Swift episodeSection
  Widget _buildEpisodeList() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingLG, AppTheme.spacingMD, AppTheme.spacingLG, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: '选集播放', icon: Icons.list),
          const SizedBox(height: AppTheme.spacingSM),
          Obx(() => EpisodeListView(
                episodeNames: _controller.currentEpisodes
                    .map((e) => e.name)
                    .toList(),
                selectedIndex: _controller.selectedEpisodeIndex.value,
                onEpisodeTap: (index) {
                  _controller.selectEpisode(index);
                  _saveHistoryForCurrentEpisode();
                },
              )),
        ],
      ),
    );
  }

  // MARK: - 影片简介

  /// 影片简介 - 对应 Swift descriptionSection (AppCard)
  Widget _buildDescription() {
    final info = _controller.vodInfo.value;
    if (info == null || info.des.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingLG, AppTheme.spacingMD, AppTheme.spacingLG, 0),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: '影片简介', icon: Icons.description_outlined),
            const SizedBox(height: AppTheme.spacingSM),
            AnimatedCrossFade(
              firstChild: Text(
                info.des,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: AppTheme.fontBody,
                  height: 1.5,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              secondChild: Text(
                info.des,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: AppTheme.fontBody,
                  height: 1.5,
                ),
              ),
              crossFadeState:
                  _isDescriptionExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 250),
            ),
            GestureDetector(
              onTap: () => setState(() => _isDescriptionExpanded = !_isDescriptionExpanded),
              child: Padding(
                padding: const EdgeInsets.only(top: AppTheme.spacingXS),
                child: Center(
                  child: Text(
                    _isDescriptionExpanded ? '收起' : '展开',
                    style: const TextStyle(
                      color: AppTheme.accentColor,
                      fontSize: AppTheme.fontFootnote,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // MARK: - 播放控制逻辑

  /// 对应 Swift saveHistoryForCurrentEpisode
  void _saveHistoryForCurrentEpisode({double? progressOverride}) {
    final info = _controller.vodInfo.value;
    if (info == null) return;

    final episodeName = info.currentEpisode?.name.trim() ?? '';
    final episodeLabel = episodeName.isEmpty
        ? '第${_controller.selectedEpisodeIndex.value + 1}集'
        : episodeName;
    final progress = (progressOverride ?? _controller.currentPlaybackSeconds()).clamp(0.0, double.infinity).toDouble();
    final timeLabel = progress > 0 ? _formatDuration(progress) : '';
    final playNote = timeLabel.isEmpty ? episodeLabel : '$episodeLabel $timeLabel';

    final playbackState = VodPlaybackState(
      flag: _controller.selectedFlag.value,
      episodeIndex: _controller.selectedEpisodeIndex.value,
      progressSeconds: progress,
    );

    CacheStore.instance.addRecord(
      info.toVideo(),
      playNote,
      playbackState: playbackState,
    );
  }

  /// 对应 Swift handlePlaybackProgress
  void _handlePlaybackProgress(double seconds) {
    _controller.updatePlaybackProgress(seconds);
    _persistHistoryIfNeeded(force: false, currentProgress: seconds);
  }

  /// 对应 Swift persistHistoryIfNeeded
  void _persistHistoryIfNeeded({required bool force, double? currentProgress}) {
    if (!_controller.isPlaying.value) return;
    final progress = (currentProgress ?? _controller.currentPlaybackSeconds()).clamp(0.0, double.infinity).toDouble();
    if (!progress.isFinite) return;

    if (!force && (progress - _lastPersistedProgress).abs() < 20) {
      return;
    }

    _lastPersistedProgress = progress;
    _saveHistoryForCurrentEpisode(progressOverride: progress);
  }

  /// 对应 Swift restorePlaybackFromHistory
  void _restorePlaybackFromHistory() {
    final video = Get.arguments;
    if (video == null || video is! Video) return;

    final playbackState = CacheStore.instance.getPlaybackState(
      video.id,
      video.sourceKey,
    );
    if (playbackState == null) return;

    _controller.applyPlaybackState(playbackState);
    _lastPersistedProgress = playbackState.progressSeconds.clamp(0.0, double.infinity).toDouble();
  }

  /// 对应 Swift refreshCollectState
  void _refreshCollectState() {
    // 收藏状态通过 Obx 实时读取，无需额外操作
  }

  /// 对应 Swift playNextEpisodeIfNeeded
  void _playNextEpisode() {
    final moved = _controller.playNext();
    if (moved) {
      _saveHistoryForCurrentEpisode();
    }
  }

  /// 对应 Swift playPreviousEpisode
  void _playPreviousEpisode() {
    final moved = _controller.playPrevious();
    if (moved) {
      _saveHistoryForCurrentEpisode();
    }
  }

  String _formatDuration(double seconds) {
    final h = (seconds ~/ 3600);
    final m = ((seconds % 3600) ~/ 60);
    final s = (seconds.toInt() % 60);
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

/// 药丸选择芯片 - 对应 Swift pillChip
class _PillChip extends StatelessWidget {
  final String title;
  final bool isSelected;
  final VoidCallback onTap;

  const _PillChip({
    required this.title,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacingLG,
          vertical: AppTheme.spacingSM,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.accentColor.withValues(alpha: 0.12)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          title,
          style: TextStyle(
            color: isSelected ? AppTheme.accentColor : AppTheme.textSecondary,
            fontSize: AppTheme.fontFootnote,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

/// VodInfo 扩展 - 转换为 Video
extension VodInfoExt on VodInfo {
  Video toVideo() => Video(
        id: id,
        name: name,
        pic: pic,
        note: note,
        year: year,
        area: area,
        director: director,
        actor: actor,
        des: des,
        sourceKey: sourceKey,
      );
}
