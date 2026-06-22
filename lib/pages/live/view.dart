import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../common/theme.dart';
import '../../models/live_models.dart';
import '../../widgets/video_player.dart';
import '../../widgets/common_widgets.dart';
import 'controller.dart';

/// 直播页 - 对应 Swift LiveView
/// 使用覆盖层抽屉模式（而非侧边栏模式）
class LivePage extends StatefulWidget {
  const LivePage({super.key});

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  final _controller = Get.put(LiveController());

  /// 是否展示频道抽屉 - 对应 Swift showChannelDrawer
  bool _showChannelDrawer = true;

  /// 底部频道信息是否显示 - 对应 Swift showCurrentChannelInfo
  bool _showCurrentChannelInfo = true;

  /// 自动隐藏频道信息的定时器 - 对应 Swift channelInfoTimer
  Timer? _channelInfoTimer;

  /// 频道信息自动隐藏延迟（秒） - 对应 Swift channelInfoAutoHideDelay
  static const double _channelInfoAutoHideDelay = 3.0;

  /// 当前频道已失败的线路索引 - 对应 Swift failedSourceIndices
  final Set<int> _failedSourceIndices = {};

  /// 当前跟踪的频道 ID - 对应 Swift trackedChannelId
  String _trackedChannelId = '';

  @override
  void initState() {
    super.initState();
    _controller.loadChannels();
    _wakeUpCurrentChannelInfo();

    // 监听频道 URL 变化 - 对应 Swift onChange(of: viewModel.currentChannel?.currentUrl)
    ever(_controller.currentChannel, (channel) {
      if (channel != null) {
        _resetFailureTracking(channel);
        _wakeUpCurrentChannelInfo();
      }
    });
  }

  @override
  void dispose() {
    _channelInfoTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Obx(() {
        if (_controller.channelGroups.isEmpty) {
          return _buildEmptyState();
        }

        return Stack(
          children: [
            // 黑色背景 - 对应 Swift Color.black.ignoresSafeArea()
            Container(color: Colors.black),

            // 播放器 - 对应 Swift VLCLivePlayerView / PlatformVideoPlayer
            _buildPlayer(),

            // 覆盖 UI - 对应 Swift overlayUI
            _buildOverlayUI(),
          ],
        );
      }),
    );
  }

  // MARK: - 空状态

  /// 空状态 - 对应 Swift emptyState
  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.tv_off, size: 48, color: Colors.grey),
          const SizedBox(height: 16),
          const Text(
            '暂无直播源',
            style: TextStyle(
              color: Colors.grey,
              fontSize: AppTheme.fontHeadline,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '请在设置中配置包含直播源的接口',
            style: TextStyle(
              color: Colors.grey.withValues(alpha: 0.7),
              fontSize: AppTheme.fontSubhead,
            ),
          ),
        ],
      ),
    );
  }

  // MARK: - 播放器

  /// 播放器 - 对应 Swift 播放器区域
  Widget _buildPlayer() {
    return Obx(() {
      final channel = _controller.currentChannel.value;
      final playUrl = channel?.currentUrl ?? '';
      final liveVisible = _controller.isLivePageVisible.value;
      if (playUrl.isEmpty) {
        return const SizedBox.shrink();
      }
      // 直播页不可见（切到其他 tab）时，**不渲染** VideoPlayerWidget，
      // 避免 IndexedStack 中 player 持续在后台播放。
      if (!liveVisible) {
        return const SizedBox.shrink();
      }
      return SizedBox.expand(
        child: VideoPlayerWidget(
          player: _controller.player,
          url: playUrl,
          videoTitle: channel?.channelName ?? '',
          onError: () {
            _handlePlaybackFailure(trigger: 'player_error');
          },
        ),
      );
    });
  }

  // MARK: - 覆盖 UI

  /// 覆盖 UI - 对应 Swift overlayUI
  Widget _buildOverlayUI() {
    return Stack(
      children: [
        // 半透明遮罩 - 对应 Swift Color.black.opacity(0.22)
        if (_showChannelDrawer)
          GestureDetector(
            onTap: () {
              setState(() => _showChannelDrawer = false);
            },
            child: Container(
              color: Colors.black.withValues(alpha: 0.22),
            ),
          ),

        // 顶部控制栏 + 底部频道信息
        Column(
          children: [
            // 顶部 - 对应 Swift HStack(channelDrawerToggleButton + Spacer)
            Padding(
              padding: const EdgeInsets.only(top: 18, left: 16, right: 16),
              child: Row(
                children: [
                  _buildChannelDrawerToggleButton(),
                  const Spacer(),
                ],
              ),
            ),

            const Spacer(),

            // 底部当前频道信息 - 对应 Swift currentChannelInfo
            Obx(() {
              final channel = _controller.currentChannel.value;
              if (channel != null && _showCurrentChannelInfo) {
                return _buildCurrentChannelInfo(channel);
              }
              return const SizedBox.shrink();
            }),
          ],
        ),

        // 频道抽屉 - 对应 Swift channelDrawer
        if (_showChannelDrawer)
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 20, bottom: 20),
            child: _buildChannelDrawer(),
          ),
      ],
    );
  }

  // MARK: - 频道抽屉切换按钮

  /// 频道抽屉切换按钮 - 对应 Swift channelDrawerToggleButton
  Widget _buildChannelDrawerToggleButton() {
    return GestureDetector(
      onTap: () {
        setState(() => _showChannelDrawer = !_showChannelDrawer);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.15),
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _showChannelDrawer ? Icons.menu : Icons.menu_open,
              color: Colors.white.withValues(alpha: 0.9),
              size: 16,
            ),
            const SizedBox(width: 8),
            Text(
              _showChannelDrawer ? '收起菜单' : '频道菜单',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // MARK: - 频道抽屉

  /// 频道抽屉 - 对应 Swift channelDrawer
  Widget _buildChannelDrawer() {
    return Container(
      width: 390,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height - 40,
      ),
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: 0.5,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 抽屉标题栏 - 对应 Swift HStack(Label + Spacer + close button)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(14),
                topRight: Radius.circular(14),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.list_alt,
                    color: Colors.white.withValues(alpha: 0.9), size: 14),
                const SizedBox(width: 10),
                Text(
                  '频道菜单',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => setState(() => _showChannelDrawer = false),
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.close,
                      color: Colors.white.withValues(alpha: 0.8),
                      size: 11,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 分组列表 + 频道列表 - 对应 Swift HStack(channelGroupList + Divider + channelList)
          Flexible(
            child: Row(
              children: [
                // 频道分组列表 - 对应 Swift channelGroupList
                SizedBox(
                  width: 150,
                  child: _buildChannelGroupList(),
                ),

                // 分割线 - 对应 Swift Divider
                Container(width: 0.5, color: Colors.white.withValues(alpha: 0.1)),

                // 频道列表 - 对应 Swift channelList
                SizedBox(
                  width: 240,
                  child: _buildChannelList(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // MARK: - 频道分组列表

  /// 频道分组列表 - 对应 Swift channelGroupList
  Widget _buildChannelGroupList() {
    return Obx(() => ListView.builder(
          itemCount: _controller.channelGroups.length,
          itemBuilder: (context, index) {
            final group = _controller.channelGroups[index];
            final isSelected = _controller.selectedGroupIndex.value == index;
            return GestureDetector(
              onTap: () => _controller.selectGroup(index),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                color: isSelected
                    ? Colors.white.withValues(alpha: 0.1)
                    : Colors.transparent,
                child: Text(
                  group.groupName,
                  style: TextStyle(
                    color: isSelected
                        ? AppTheme.accentColor
                        : Colors.white.withValues(alpha: 0.8),
                    fontSize: 14,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  ),
                ),
              ),
            );
          },
        ));
  }

  // MARK: - 频道列表

  /// 频道列表 - 对应 Swift channelList
  Widget _buildChannelList() {
    return Obx(() {
      final channels = _controller.currentChannels;
      return ListView.builder(
        itemCount: channels.length,
        itemBuilder: (context, index) {
          final channel = channels[index];
          final isCurrent =
              _controller.currentChannel.value?.channelName == channel.channelName;
          return GestureDetector(
            onTap: () {
              _controller.selectedChannelIndex.value = index;
              _controller.selectChannel(channel);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              color: isCurrent
                  ? AppTheme.accentColor.withValues(alpha: 0.12)
                  : Colors.transparent,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      channel.channelName,
                      style: TextStyle(
                        color: isCurrent
                            ? AppTheme.accentColor
                            : Colors.white.withValues(alpha: 0.8),
                        fontSize: 14,
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // 多线路数量标识 - 对应 Swift sourceNum badge
                  if (channel.sourceNum > 1)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.2),
                          width: 0.5,
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${channel.sourceNum}',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.3),
                          fontSize: 10,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      );
    });
  }

  // MARK: - 当前频道信息

  /// 底部当前频道信息 - 对应 Swift currentChannelInfo
  Widget _buildCurrentChannelInfo(LiveChannelItem channel) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 600),
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppTheme.backgroundSecondary.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.08),
            width: 0.5,
          ),
        ),
        child: Row(
          children: [
            // 频道名称 + 线路信息 - 对应 Swift VStack
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: AppTheme.accentColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        channel.channelName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  if (channel.sourceNum > 1) ...[
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.only(left: 18),
                      child: Text(
                        '正在播放：线路 ${channel.sourceIndex + 1} / ${channel.sourceNum}',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // 操作按钮 - 对应 Swift HStack(切换线路 + 全屏)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 切换线路按钮 - 对应 Swift switchSource button
                if (channel.sourceNum > 1)
                  GestureDetector(
                    onTap: () {
                      _wakeUpCurrentChannelInfo();
                      _resetFailureTracking(channel);
                      _controller.switchSource();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 9),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF5CB67B), Color(0xFF7DCEA0)],
                        ),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.shuffle, color: Colors.white, size: 14),
                          SizedBox(width: 6),
                          Text(
                            '切换线路',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // MARK: - 频道信息自动隐藏

  /// 唤醒频道信息显示 - 对应 Swift wakeUpCurrentChannelInfo
  void _wakeUpCurrentChannelInfo() {
    if (!mounted) return;
    setState(() => _showCurrentChannelInfo = true);
    _channelInfoTimer?.cancel();

    if (_controller.currentChannel.value == null) return;

    _channelInfoTimer = Timer(
      const Duration(seconds: 3),
      () {
        if (mounted) {
          setState(() => _showCurrentChannelInfo = false);
        }
      },
    );
  }

  /// 用户交互回调 - 对应 Swift reportUserActivity
  void _reportUserActivity() {
    _wakeUpCurrentChannelInfo();
  }

  // MARK: - 播放失败处理

  /// 重置失败追踪 - 对应 Swift resetFailureTracking
  void _resetFailureTracking(LiveChannelItem channel) {
    _failedSourceIndices.clear();
    _trackedChannelId = channel.id;
  }

  /// 处理播放失败 - 对应 Swift handlePlaybackFailure
  void _handlePlaybackFailure({required String trigger}) {
    final channel = _controller.currentChannel.value;
    if (channel == null) return;
    if (channel.sourceNum <= 1) return;

    if (_trackedChannelId != channel.id) {
      _resetFailureTracking(channel);
    }

    final failedIndex = channel.sourceIndex;
    if (_failedSourceIndices.contains(failedIndex)) return;
    _failedSourceIndices.add(failedIndex);

    _switchToNextAvailableSource(totalSources: channel.sourceNum);
  }

  /// 切换到下一个可用线路 - 对应 Swift switchToNextAvailableSource
  bool _switchToNextAvailableSource({required int totalSources}) {
    if (_failedSourceIndices.length >= totalSources) return false;

    for (var i = 0; i < totalSources; i++) {
      _controller.switchSource();
      final nextIndex = _controller.currentChannel.value?.sourceIndex;
      if (nextIndex != null && !_failedSourceIndices.contains(nextIndex)) {
        return true;
      }
    }

    return false;
  }
}
