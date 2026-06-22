import 'dart:async';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import '../../models/live_models.dart';
import '../../services/api_config.dart';

class LiveController extends GetxController {
  final channelGroups = <LiveChannelGroup>[].obs;
  final selectedGroupIndex = 0.obs;
  final selectedChannelIndex = 0.obs;
  final currentChannel = Rx<LiveChannelItem?>(null);
  final epgList = <Epginfo>[].obs;
  final isLoading = false.obs;
  final showChannelList = false.obs;

  /// 直播页是否可见（由 ContentView tab 切换驱动）：
  /// 不可见时自动 pause 播放器，避免在 IndexedStack 中
  /// 切到其他 tab 后声音还在后台播放的问题。
  final isLivePageVisible = true.obs;

  /// 直播播放器（懒创建）：抽到 controller 持有，
  /// 便于在页面不可见时主动 pause / 切回时 resume，
  /// 而不必重建 VideoPlayerWidget。
  Player? _player;
  Player get player {
    _player ??= Player(configuration: const PlayerConfiguration(title: 'TVBox Live'));
    return _player!;
  }

  StreamSubscription? _channelGroupsSubscription;

  @override
  void onInit() {
    super.onInit();
    bindLiveChannelGroups();
  }

  @override
  void onClose() {
    _channelGroupsSubscription?.cancel();
    // 释放 player
    try {
      _player?.dispose();
    } catch (_) {}
    _player = null;
    super.onClose();
  }

  /// 暂停直播播放（不释放 player，保留播放位置）
  void pausePlayback() {
    try {
      _player?.pause();
    } catch (_) {}
  }

  /// 恢复直播播放
  void resumePlayback() {
    try {
      if (_player != null && currentChannel.value != null) {
        _player?.play();
      }
    } catch (_) {}
  }

  void loadChannels() {
    applyChannelGroups(ApiConfig.instance.liveChannelGroupList.toList());
  }

  void selectGroup(int index) {
    if (index < 0 || index >= channelGroups.length) return;
    selectedGroupIndex.value = index;
    selectedChannelIndex.value = 0;
    final channels = channelGroups[index].channels;
    if (channels.isNotEmpty) {
      selectChannel(channels.first);
    }
  }

  void selectChannel(LiveChannelItem channel) {
    currentChannel.value = channel;
    // 切换频道时主动 open media 到 player，避免 LivePage 还没 build 时
    // video_player 内部还是用上一个 url。
    final url = channel.currentUrl;
    if (url.isNotEmpty) {
      try {
        player.open(Media(url));
      } catch (_) {}
    }
    _loadEPG(channel);
  }

  void previousChannel() {
    if (channelGroups.isEmpty) return;
    if (selectedChannelIndex.value > 0) {
      selectedChannelIndex.value--;
    } else if (selectedGroupIndex.value > 0) {
      selectedGroupIndex.value--;
      final group = channelGroups[selectedGroupIndex.value];
      selectedChannelIndex.value = group.channels.length - 1;
    }
    final channels = currentChannels;
    if (selectedChannelIndex.value < channels.length) {
      selectChannel(channels[selectedChannelIndex.value]);
    }
  }

  void nextChannel() {
    if (channelGroups.isEmpty) return;
    final group = channelGroups[selectedGroupIndex.value];
    if (selectedChannelIndex.value < group.channels.length - 1) {
      selectedChannelIndex.value++;
    } else if (selectedGroupIndex.value < channelGroups.length - 1) {
      selectedGroupIndex.value++;
      selectedChannelIndex.value = 0;
    }
    final channels = currentChannels;
    if (selectedChannelIndex.value < channels.length) {
      selectChannel(channels[selectedChannelIndex.value]);
    }
  }

  void switchSource() {
    currentChannel.value?.nextSource();
    // 触发 Obx 刷新 - 重新赋值
    currentChannel.refresh();
  }

  List<LiveChannelItem> get currentChannels {
    if (selectedGroupIndex.value < channelGroups.length) {
      return channelGroups[selectedGroupIndex.value].channels;
    }
    return [];
  }

  void _loadEPG(LiveChannelItem channel) {
    // 预留：后续可在此按频道名/频道 ID 请求远程 EPG。
    // 当前版本先清空，避免展示过期节目单。
    epgList.clear();
  }

  void bindLiveChannelGroups() {
    _channelGroupsSubscription?.cancel();
    _channelGroupsSubscription =
        ApiConfig.instance.liveChannelGroupList.listen((groups) {
      applyChannelGroups(groups);
    });
  }

  void applyChannelGroups(List<LiveChannelGroup> groups) {
    final previousChannelId = currentChannel.value?.id;
    channelGroups.value = groups;

    if (groups.isEmpty) {
      selectedGroupIndex.value = 0;
      selectedChannelIndex.value = 0;
      currentChannel.value = null;
      return;
    }

    if (previousChannelId != null) {
      final located = _locateChannel(
        channelId: previousChannelId,
        groups: groups,
      );
      if (located != null) {
        selectedGroupIndex.value = located.$1;
        selectedChannelIndex.value = located.$2;
        currentChannel.value = groups[located.$1].channels[located.$2];
        return;
      }
    }

    final clampedGroupIndex =
        selectedGroupIndex.value.clamp(0, groups.length - 1);
    selectedGroupIndex.value = clampedGroupIndex;

    final channels = groups[clampedGroupIndex].channels;
    if (channels.isEmpty) {
      selectedChannelIndex.value = 0;
      currentChannel.value = null;
      return;
    }

    final clampedChannelIndex =
        selectedChannelIndex.value.clamp(0, channels.length - 1);
    selectedChannelIndex.value = clampedChannelIndex;
    currentChannel.value = channels[clampedChannelIndex];
  }

  (int, int)? _locateChannel({
    required String channelId,
    required List<LiveChannelGroup> groups,
  }) {
    for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) {
      final group = groups[groupIndex];
      for (var channelIndex = 0;
          channelIndex < group.channels.length;
          channelIndex++) {
        if (group.channels[channelIndex].id == channelId) {
          return (groupIndex, channelIndex);
        }
      }
    }
    return null;
  }
}
