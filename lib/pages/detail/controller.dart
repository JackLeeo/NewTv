import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/movie.dart';
import '../../models/vod_info.dart';
import '../../models/cache_store.dart';
import '../../services/api_config.dart';
import '../../services/source_service.dart';
import '../../services/spider_service.dart';
import '../../services/network_manager.dart';

class PlaybackQualityOption {
  static const String autoIdentifier = 'auto';

  final String id;
  final String name;
  final String url;

  const PlaybackQualityOption({
    required this.id,
    required this.name,
    required this.url,
  });

  bool get isAuto => id == autoIdentifier;

  static PlaybackQualityOption auto(String url) {
    return PlaybackQualityOption(
      id: autoIdentifier,
      name: '自动',
      url: url,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaybackQualityOption &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

class DetailController extends GetxController with WidgetsBindingObserver {
  final vodInfo = Rx<VodInfo?>(null);
  final isLoading = false.obs;
  final errorMessage = Rx<String?>(null);
  final selectedFlag = ''.obs;
  final selectedEpisodeIndex = 0.obs;
  final isPlaying = false.obs;
  final playUrl = Rx<String?>(null);
  final playHeaders = <String, String>{}.obs;
  final playbackSessionId = ''.obs;
  final resumeSeconds = 0.0.obs;
  final qualityOptions = <PlaybackQualityOption>[].obs;
  final selectedQualityId = PlaybackQualityOption.autoIdentifier.obs;

  /// 是否处于全屏模式 - 对应 Swift isFullScreenMode
  final isFullScreen = false.obs;

  /// 跳过片头秒数（0 表示关闭）- 对应 Swift skipIntroSeconds
  final skipIntroSeconds = 0.obs;

  /// 跳过片尾秒数（0 表示关闭）- 对应 Swift skipOutroSeconds
  final skipOutroSeconds = 0.obs;

  double _realtimeProgressSeconds = 0;

  String _qualityBaseEpisodeURL = '';
  final Map<String, List<PlaybackQualityOption>> _qualityOptionCache = {};
  String _qualityResolveToken = '';
  String _spiderResolveToken = '';

  /// 切换全屏模式 - 对应 Swift onToggleFullScreen
  void toggleFullScreen() {
    isFullScreen.value = !isFullScreen.value;
  }

  /// 设置跳过片头秒数
  Future<void> setSkipIntroSeconds(int seconds) async {
    skipIntroSeconds.value = seconds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('skip_intro_seconds', seconds);
  }

  /// 设置跳过片尾秒数
  Future<void> setSkipOutroSeconds(int seconds) async {
    skipOutroSeconds.value = seconds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('skip_outro_seconds', seconds);
  }

  /// 加载持久化的跳过时间
  Future<void> loadSkipDurations() async {
    final prefs = await SharedPreferences.getInstance();
    skipIntroSeconds.value = prefs.getInt('skip_intro_seconds') ?? 0;
    skipOutroSeconds.value = prefs.getInt('skip_outro_seconds') ?? 0;
  }

  @override
  void onInit() {
    super.onInit();
    loadSkipDurations();
    // 监听 lifecycle：应用从后台/锁屏切回前台时强制重置 isLoading
    // 并重新加载详情（避免旧 dio in-flight 请求卡住 isLoading）
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      isLoading.value = false;
      final info = vodInfo.value;
      // 如果之前已经加载过详情但因为 dio 死连接而 vodInfo 是 null 或 playUrl 是 null，
      // 在切回前台时主动重新触发一次加载/解析
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (isClosed) return;
        // 优先解析播放 URL（如果 detail 已有但 playUrl 没解析出来）
        if (info != null && playUrl.value == null) {
          final episode = info.currentEpisode;
          if (episode != null) {
            updateQualityOptions(episode.url, resetSelection: false);
            if (isSpiderSource) {
              _resolveSpiderPlayUrl(flag: selectedFlag.value, id: episode.url);
            }
          }
        }
      });
    }
  }

  List<Episode> get currentEpisodes =>
      vodInfo.value?.playUrlMap[selectedFlag.value] ?? [];

  List<String> get flags => vodInfo.value?.playFlags ?? [];

  bool get hasQualityChoices => qualityOptions.length > 1;

  bool get isSpiderSource {
    final sourceKey = vodInfo.value?.sourceKey;
    if (sourceKey == null) return false;
    return ApiConfig.instance.getSource(sourceKey)?.isSpiderSource ?? false;
  }

  Future<void> loadDetail(Video video) async {
    final source = ApiConfig.instance.getSource(video.sourceKey) ??
        ApiConfig.instance.homeSourceBean.value;
    if (source == null) return;

    isLoading.value = true;
    errorMessage.value = null;

    try {
      final info = await SourceService.instance.getDetail(source, video.id);
      if (info != null) {
        vodInfo.value = info;
        selectedFlag.value = info.playFlag;
        selectedEpisodeIndex.value = info.playIndex;
        resumeSeconds.value = 0;
        _realtimeProgressSeconds = 0;

        final episode = info.currentEpisode;
        if (episode != null) {
          updateQualityOptions(episode.url, resetSelection: true);
        } else {
          resetQualityState();
        }
      }
    } catch (e) {
      errorMessage.value = e.toString();
    }

    isLoading.value = false;
  }

  void selectFlag(String flag) {
    if (selectedFlag.value == flag) return;
    final currentIndex = selectedEpisodeIndex.value;

    isPlaying.value = false;
    playUrl.value = null;
    playHeaders.clear();

    selectedFlag.value = flag;
    vodInfo.value?.playFlag = flag;
    resumeSeconds.value = 0;
    _realtimeProgressSeconds = 0;

    final episodes = vodInfo.value?.playUrlMap[flag] ?? [];
    if (episodes.isEmpty) {
      selectedEpisodeIndex.value = 0;
      vodInfo.value?.playIndex = 0;
      resetQualityState();
      return;
    }

    final targetIndex = currentIndex.clamp(0, episodes.length - 1);
    selectedEpisodeIndex.value = targetIndex;
    vodInfo.value?.playIndex = targetIndex;
    final episodeURL = episodes[targetIndex].url;
    updateQualityOptions(episodeURL, resetSelection: true);

    if (isPlaying.value) {
      if (isSpiderSource) {
        _resolveSpiderPlayUrl(flag: flag, id: episodeURL);
      } else {
        playUrl.value = _selectedPlayableURL(fallback: episodeURL);
        playbackSessionId.value = _newUuid();
      }
    }
  }

  void selectEpisode(int index) {
    if (selectedEpisodeIndex.value == index && isPlaying.value) return;

    isPlaying.value = false;
    playUrl.value = null;
    playHeaders.clear();
    resumeSeconds.value = 0;
    _realtimeProgressSeconds = 0;

    selectedEpisodeIndex.value = index;
    vodInfo.value?.playIndex = index;

    final episode = vodInfo.value?.currentEpisode;
    if (episode != null) {
      final shouldResetQuality = _qualityBaseEpisodeURL != episode.url;
      updateQualityOptions(episode.url, resetSelection: shouldResetQuality);

      if (isSpiderSource) {
        _resolveSpiderPlayUrl(flag: selectedFlag.value, id: episode.url);
      } else {
        playUrl.value = _selectedPlayableURL(fallback: episode.url);
        playHeaders.clear();
        playbackSessionId.value = _newUuid();
        isPlaying.value = true;
      }
    }
  }

  void applyPlaybackState(VodPlaybackState state) {
    final info = vodInfo.value;
    if (info == null || info.playFlags.isEmpty) return;

    final fallbackFlag =
        info.playFlag.isEmpty ? info.playFlags[0] : info.playFlag;
    final targetFlag =
        info.playFlags.contains(state.flag) ? state.flag : fallbackFlag;

    selectedFlag.value = targetFlag;
    info.playFlag = targetFlag;

    final episodes = info.playUrlMap[targetFlag] ?? [];
    if (episodes.isEmpty) return;

    final targetIndex = state.episodeIndex.clamp(0, episodes.length - 1);
    selectedEpisodeIndex.value = targetIndex;
    info.playIndex = targetIndex;

    final progress = state.progressSeconds > 0 ? state.progressSeconds : 0.0;
    resumeSeconds.value = progress;
    _realtimeProgressSeconds = progress;
    final episodeURL = episodes[targetIndex].url;
    updateQualityOptions(episodeURL, resetSelection: true);

    if (isSpiderSource) {
      _resolveSpiderPlayUrl(flag: targetFlag, id: episodeURL);
    } else {
      playUrl.value = _selectedPlayableURL(fallback: episodeURL);
      playbackSessionId.value = _newUuid();
      isPlaying.value = true;
    }
  }

  void selectQuality(PlaybackQualityOption option) {
    if (!qualityOptions.contains(option)) return;
    selectedQualityId.value = option.id;
    if (!isPlaying.value) return;

    final targetURL =
        option.url.isEmpty ? _qualityBaseEpisodeURL : option.url;
    if (targetURL.isEmpty || playUrl.value == targetURL) return;

    final progress = currentPlaybackSeconds();
    resumeSeconds.value = progress > 0 ? progress : 0;
    _realtimeProgressSeconds = resumeSeconds.value;
    playUrl.value = targetURL;
    playbackSessionId.value = _newUuid();
  }

  void updatePlaybackProgress(double seconds) {
    if (!seconds.isFinite) return;
    _realtimeProgressSeconds = seconds > 0 ? seconds : 0;
  }

  double currentPlaybackSeconds() {
    return _realtimeProgressSeconds > resumeSeconds.value
        ? _realtimeProgressSeconds
        : resumeSeconds.value;
  }

  void commitPlaybackProgressSnapshot() {
    final snapshot = _realtimeProgressSeconds > 0 ? _realtimeProgressSeconds : 0;
    if ((snapshot - resumeSeconds.value).abs() >= 1) {
      resumeSeconds.value = snapshot.toDouble();
    }
  }

  bool playNext() {
    final info = vodInfo.value;
    if (info == null) return false;
    final episodes = info.currentEpisodes;
    if (selectedEpisodeIndex.value + 1 < episodes.length) {
      selectEpisode(selectedEpisodeIndex.value + 1);
      return true;
    }
    return false;
  }

  bool playPrevious() {
    if (selectedEpisodeIndex.value > 0) {
      selectEpisode(selectedEpisodeIndex.value - 1);
      return true;
    }
    return false;
  }

  void _resolveSpiderPlayUrl({required String flag, required String id}) {
    final token = _newUuid();
    _spiderResolveToken = token;

    // 获取当前 Spider 的 key/type/apiBase
    final spiderInfo = SpiderService.instance.getCurrentSpiderInfo();

    () async {
      try {
        final result =
            await SpiderService.instance.getPlayUrl(
          spiderInfo.$1, spiderInfo.$2, spiderInfo.$3,
          flag, id);

        if (_spiderResolveToken != token) return;
        if (result == null) {
          errorMessage.value = 'Spider播放地址解析失败';
          return;
        }

        var headers = <String, String>{};
        if (result['header'] != null) {
          final headerDict = result['header'];
          if (headerDict is Map<String, String>) {
            headers = headerDict;
          } else if (headerDict is Map) {
            for (final entry in headerDict.entries) {
              headers[entry.key.toString()] = entry.value.toString();
            }
          }
        }

        String? resolvedUrl;
        final urlValue = result['url'];
        if (urlValue is String && urlValue.isNotEmpty) {
          resolvedUrl = urlValue;
        } else if (urlValue is List) {
          for (int i = 0; i < urlValue.length - 1; i += 2) {
            if (i + 1 >= urlValue.length) break;
            final urlStr = urlValue[i + 1].toString();
            if (urlStr.isNotEmpty) {
              resolvedUrl = urlStr;
              break;
            }
          }
        }

        if (_spiderResolveToken != token) return;

        if (resolvedUrl != null && resolvedUrl.isNotEmpty) {
          playUrl.value = resolvedUrl;
          playHeaders.value = headers;
          playbackSessionId.value = _newUuid();
          isPlaying.value = true;
        } else {
          errorMessage.value = 'Spider播放地址解析失败';
        }
      } catch (e) {
        if (_spiderResolveToken != token) return;
        errorMessage.value = 'Spider播放解析错误: $e';
      }
    }();
  }

  String _selectedPlayableURL({required String fallback}) {
    final selected = qualityOptions
        .firstWhereOrNull((o) => o.id == selectedQualityId.value)
        ?.url;
    if (selected != null && selected.isNotEmpty) {
      return selected;
    }
    return fallback;
  }

  void resetQualityState() {
    _qualityBaseEpisodeURL = '';
    qualityOptions.clear();
    selectedQualityId.value = PlaybackQualityOption.autoIdentifier;
    _qualityResolveToken = _newUuid();
  }

  void updateQualityOptions(String episodeURL, {required bool resetSelection}) {
    final trimmedEpisodeURL = episodeURL.trim();
    if (trimmedEpisodeURL.isEmpty) {
      resetQualityState();
      return;
    }

    final autoOption = PlaybackQualityOption.auto(trimmedEpisodeURL);
    final previousSelected = selectedQualityId.value;

    _qualityBaseEpisodeURL = trimmedEpisodeURL;
    if (resetSelection) {
      selectedQualityId.value = PlaybackQualityOption.autoIdentifier;
    }

    qualityOptions.value = [autoOption];

    if (_qualityOptionCache.containsKey(trimmedEpisodeURL)) {
      final cached = _qualityOptionCache[trimmedEpisodeURL]!;
      qualityOptions.value = cached;
      if (resetSelection ||
          !cached.any((o) => o.id == selectedQualityId.value)) {
        selectedQualityId.value = PlaybackQualityOption.autoIdentifier;
      } else if (previousSelected != selectedQualityId.value &&
          cached.any((o) => o.id == previousSelected)) {
        selectedQualityId.value = previousSelected;
      }
      return;
    }

    final token = _newUuid();
    _qualityResolveToken = token;

    () async {
      final resolved = await _resolveQualityOptions(trimmedEpisodeURL);
      if (_qualityResolveToken != token ||
          _qualityBaseEpisodeURL != trimmedEpisodeURL) {
        return;
      }
      if (resolved.isEmpty) return;

      _qualityOptionCache[trimmedEpisodeURL] = resolved;
      qualityOptions.value = resolved;

      if (resetSelection) {
        selectedQualityId.value = PlaybackQualityOption.autoIdentifier;
      } else if (resolved.any((o) => o.id == selectedQualityId.value)) {
        // 当前选择仍有效，保持不变
      } else if (resolved.any((o) => o.id == previousSelected)) {
        selectedQualityId.value = previousSelected;
      } else {
        selectedQualityId.value = PlaybackQualityOption.autoIdentifier;
      }
    }();
  }

  Future<List<PlaybackQualityOption>> _resolveQualityOptions(
      String episodeURL) async {
    if (!_looksLikeHLSURL(episodeURL)) return [];
    try {
      final playlist =
          await NetworkManager.instance.getString(episodeURL);
      return _parseMasterPlaylist(playlist, masterURL: episodeURL);
    } catch (_) {
      return [];
    }
  }

  bool _looksLikeHLSURL(String url) {
    final lowercased = url.toLowerCase();
    if (lowercased.contains('.m3u8')) return true;
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final ext = uri.path.split('.').last.toLowerCase();
    return ext == 'm3u8' || ext == 'm3u';
  }

  List<PlaybackQualityOption> _parseMasterPlaylist(
    String content, {
    required String masterURL,
  }) {
    if (!content.toLowerCase().contains('#EXT-X-STREAM-INF')) return [];

    final lines = content.split(RegExp(r'\r?\n'));
    final variants = <_HLSVariant>[];
    var index = 0;

    while (index < lines.length) {
      final line = lines[index].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF:')) {
        index++;
        continue;
      }

      final attributeString =
          line.substring('#EXT-X-STREAM-INF:'.length);
      final attributes = _parseAttributeMap(attributeString);

      String? uri;
      var nextIndex = index + 1;
      while (nextIndex < lines.length) {
        final candidate = lines[nextIndex].trim();
        if (candidate.isEmpty) {
          nextIndex++;
          continue;
        }
        if (candidate.startsWith('#')) {
          nextIndex++;
          continue;
        }
        uri = candidate;
        break;
      }

      if (uri != null && uri.isNotEmpty) {
        final resolvedURL = _resolveRelativeURL(uri, masterURL);
        final name = attributes['NAME']?.trim();
        final bandwidth = int.tryParse(attributes['BANDWIDTH'] ?? '');
        int? height;
        final resolution = attributes['RESOLUTION'];
        if (resolution != null) {
          final parts = resolution.split('x');
          if (parts.length == 2) {
            height = int.tryParse(parts[1]);
          }
        }

        variants.add(_HLSVariant(
          url: resolvedURL,
          name: (name != null && name.isNotEmpty) ? name : null,
          height: height,
          bandwidth: bandwidth,
        ));
      }

      index = nextIndex + 1;
    }

    if (variants.isEmpty) return [];

    // 去重
    final seenURLs = <String>{};
    final deduped = <_HLSVariant>[];
    for (final variant in variants) {
      if (seenURLs.add(variant.url)) {
        deduped.add(variant);
      }
    }

    // 排序：高度降序 > 带宽降序 > URL 升序
    deduped.sort((lhs, rhs) {
      final lhsHeight = lhs.height ?? -1;
      final rhsHeight = rhs.height ?? -1;
      if (lhsHeight != rhsHeight) return rhsHeight.compareTo(lhsHeight);
      final lhsBandwidth = lhs.bandwidth ?? -1;
      final rhsBandwidth = rhs.bandwidth ?? -1;
      if (lhsBandwidth != rhsBandwidth) {
        return rhsBandwidth.compareTo(lhsBandwidth);
      }
      return lhs.url.compareTo(rhs.url);
    });

    final displayNameCount = <String, int>{};
    final options = <PlaybackQualityOption>[];
    for (var i = 0; i < deduped.length; i++) {
      final variant = deduped[i];
      String baseName;
      if (variant.name != null && variant.name!.isNotEmpty) {
        baseName = variant.name!;
      } else if (variant.height != null) {
        baseName = '${variant.height}p';
      } else if (variant.bandwidth != null && variant.bandwidth! > 0) {
        baseName = '${variant.bandwidth! ~/ 1000}K';
      } else {
        baseName = '清晰度${i + 1}';
      }

      final newCount = (displayNameCount[baseName] ?? 0) + 1;
      displayNameCount[baseName] = newCount;
      final finalName = newCount > 1 ? '$baseName $newCount' : baseName;

      final option = PlaybackQualityOption(
        id: variant.url,
        name: finalName,
        url: variant.url,
      );
      if (option.url.isNotEmpty && option.url != masterURL) {
        options.add(option);
      }
    }

    if (options.length < 2) return [];

    final merged = <PlaybackQualityOption>[
      PlaybackQualityOption.auto(masterURL),
      ...options,
    ];
    return merged;
  }

  Map<String, String> _parseAttributeMap(String raw) {
    final result = <String, String>{};
    final pairs = _splitAttributes(raw);
    for (final pair in pairs) {
      final components = pair.split('=');
      if (components.length < 2) continue;
      final key = components[0].trim();
      var value = components.sublist(1).join('=').trim();
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      if (key.isNotEmpty) {
        result[key] = value;
      }
    }
    return result;
  }

  List<String> _splitAttributes(String raw) {
    final parts = <String>[];
    final buffer = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < raw.length; i++) {
      final char = raw[i];
      if (char == '"') {
        inQuotes = !inQuotes;
        buffer.write(char);
        continue;
      }

      if (char == ',' && !inQuotes) {
        final item = buffer.toString().trim();
        if (item.isNotEmpty) {
          parts.add(item);
        }
        buffer.clear();
        continue;
      }

      buffer.write(char);
    }

    final tail = buffer.toString().trim();
    if (tail.isNotEmpty) {
      parts.add(tail);
    }
    return parts;
  }

  String _resolveRelativeURL(String uri, String baseURL) {
    final baseUri = Uri.tryParse(baseURL);
    if (baseUri == null) return uri;
    // 如果已经是绝对 URL，直接返回
    if (uri.startsWith('http://') || uri.startsWith('https://')) return uri;
    final resolved = baseUri.resolve(uri);
    return resolved.toString();
  }

  void saveRecord() {
    final info = vodInfo.value;
    if (info == null || !isPlaying.value) return;

    final progress = currentPlaybackSeconds();
    final episode = currentEpisodes.isNotEmpty &&
            selectedEpisodeIndex.value < currentEpisodes.length
        ? currentEpisodes[selectedEpisodeIndex.value]
        : null;

    final playNote = episode != null
        ? '${selectedFlag.value} - ${episode.name}'
        : '';

    CacheStore.instance.addRecord(
      Video(
        id: info.id,
        name: info.name,
        pic: info.pic,
        sourceKey: info.sourceKey,
      ),
      playNote,
      playbackState: VodPlaybackState(
        flag: selectedFlag.value,
        episodeIndex: selectedEpisodeIndex.value,
        progressSeconds: progress,
      ),
    );
  }

  String _newUuid() {
    return '${DateTime.now().microsecondsSinceEpoch}_${Object.hash(DateTime.now(), _qualityResolveToken)}';
  }
}

class _HLSVariant {
  final String url;
  final String? name;
  final int? height;
  final int? bandwidth;

  const _HLSVariant({
    required this.url,
    this.name,
    this.height,
    this.bandwidth,
  });
}
