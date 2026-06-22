import 'dart:convert';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_config.dart';
import '../models/source_bean.dart';
import '../models/live_models.dart';
import '../common/constants.dart';
import 'network_manager.dart';

/// 配置错误枚举
enum ConfigError {
  parseError,
  networkError;

  String message([String? detail]) {
    switch (this) {
      case ConfigError.parseError:
        return '配置解析错误${detail != null ? ': $detail' : ''}';
      case ConfigError.networkError:
        return '网络错误${detail != null ? ': $detail' : ''}';
    }
  }
}

/// 多仓库可选项
class MultiRepoOption {
  final String name;
  final String url;

  const MultiRepoOption({required this.name, required this.url});

  String get id => url.toLowerCase();
}

/// 核心配置管理器 - 对应 Swift ApiConfig
/// 负责加载和解析远程 JSON 配置，管理视频源列表
class ApiConfig extends GetxController {
  static ApiConfig get instance => Get.find<ApiConfig>();

  static const int _maxConfigResolveDepth = 6;

  /// 安全解析 int - 对应 Swift as? Int ?? defaultValue
  /// 处理 null, int, double, String 类型
  static int _safeParseInt(dynamic value, int defaultValue) {
    if (value == null) return defaultValue;
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value) ?? defaultValue;
    return defaultValue;
  }
  static const int _maxRedirectCandidates = 20;
  static const int _rawConfigCacheTTL = 20; // 秒
  static const int _maxRawConfigCacheEntries = 24;

  final sourceBeanList = <SourceBean>[].obs;
  final homeSourceBean = Rx<SourceBean?>(null);
  final parseBeanList = <ParseBean>[].obs;
  final liveChannelGroupList = <LiveChannelGroup>[].obs;
  final dohList = <(String, String)>[].obs;
  final isLoaded = false.obs;
  final configUrl = ''.obs;
  final liveConfigUrl = ''.obs;
  final wallpaper = ''.obs;

  final NetworkManager _network = NetworkManager.instance;

  /// 加载令牌，用于取消之前的加载
  int _activeLoadToken = 0;

  /// 原始配置缓存
  final Map<String, _RawConfigCacheEntry> _rawConfigCache = {};

  ApiConfig();

  // ============================================================
  // 公开 API
  // ============================================================

  /// 加载远程配置
  Future<void> loadConfig(String apiUrl) async {
    await loadConfigs(vodApiUrl: apiUrl, liveApiUrl: apiUrl);
  }

  /// 分别加载点播配置和直播配置
  Future<void> loadConfigs({
    required String vodApiUrl,
    required String liveApiUrl,
  }) async {
    final trimmedVod = vodApiUrl.trim();
    final trimmedLive = liveApiUrl.trim();

    if (trimmedVod.isEmpty) {
      throw ConfigError.parseError.message('点播接口地址不能为空');
    }

    final loadToken = DateTime.now().microsecondsSinceEpoch;
    _activeLoadToken = loadToken;

    final resolvedLive = trimmedLive.isEmpty ? trimmedVod : trimmedLive;
    configUrl.value = trimmedVod;
    liveConfigUrl.value = resolvedLive;

    if (trimmedVod == resolvedLive) {
      final configResult = await _fetchConfig(trimmedVod);
      if (_activeLoadToken != loadToken) return;
      await _parseConfig(
        configResult.config,
        apiUrl: configResult.loadedFrom,
        includeSources: true,
        includeLive: false,
        loadToken: loadToken,
      );
      // 后台解析直播
      await _parseConfig(
        configResult.config,
        apiUrl: configResult.loadedFrom,
        includeSources: false,
        includeLive: true,
        loadToken: loadToken,
      );
    } else {
      final vodConfig = await _fetchConfig(trimmedVod);
      final liveConfig = await _fetchConfig(resolvedLive);
      if (_activeLoadToken != loadToken) return;
      await _parseConfig(
        vodConfig.config,
        apiUrl: vodConfig.loadedFrom,
        includeSources: true,
        includeLive: false,
        loadToken: loadToken,
      );
      await _parseConfig(
        liveConfig.config,
        apiUrl: liveConfig.loadedFrom,
        includeSources: false,
        includeLive: true,
        loadToken: loadToken,
      );
    }

    if (_activeLoadToken != loadToken) return;
    isLoaded.value = true;
  }

  /// 仅探测"多仓库入口"并返回可选项。
  /// 返回 null 表示不是多仓库入口；返回数组表示是多仓库入口（数组可能为空）。
  Future<List<MultiRepoOption>?> fetchMultiRepoOptions(String apiUrl) async {
    final normalizedUrl = normalizeConfigUrl(apiUrl);

    if (_isSpiderSourceUrl(normalizedUrl)) {
      return null;
    }

    final jsonStr = await _fetchConfigText(normalizedUrl);
    final cleanedJson = stripJsonComments(jsonStr);

    Map<String, dynamic>? decoded;
    try {
      decoded = jsonDecode(cleanedJson) as Map<String, dynamic>?;
    } catch (_) {}

    if (decoded != null) {
      final config = AppConfigData.fromJson(decoded);
      if (config.hasUsableContent) return null;

      // 尝试多仓库
      try {
        final multiRepo = MultiRepoConfigData.fromJson(decoded);
        final normalizedCandidates = _uniqueUrlsInOrder(
          multiRepo.candidateUrls.map(normalizeConfigUrl).toList(),
        );

        final options = <MultiRepoOption>[];
        for (final candidate in normalizedCandidates) {
          final matchedEntry = multiRepo.urls?.firstWhere(
            (e) => normalizeConfigUrl(e.url ?? '') == candidate,
            orElse: () => MultiRepoEntry(),
          );
          final displayName = matchedEntry?.name?.trim();
          final fallbackName = Uri.tryParse(candidate)?.host ?? candidate;
          final resolvedName =
              (displayName != null && displayName.isNotEmpty) ? displayName : fallbackName;
          options.add(MultiRepoOption(name: resolvedName, url: candidate));
        }

        return options;
      } catch (_) {
        return null;
      }
    }

    return null;
  }

  /// 获取指定 key 的源
  SourceBean? getSource(String key) {
    return sourceBeanList.firstWhereOrNull((s) => s.key == key);
  }

  /// 获取可搜索的源列表
  List<SourceBean> getSearchableSources() {
    final result = sourceBeanList
        .where((s) => s.isSearchable && s.key != 'douban' && s.key != 'baseset')
        .toList();
    print('[ApiConfig] getSearchableSources: 总源数=${sourceBeanList.length}, 可搜索源数=${result.length}');
    return result;
  }

  /// 设置主页源
  Future<void> setHomeSource(SourceBean source) async {
    homeSourceBean.value = source;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.homeApi, source.key);
  }

  /// 从 Spider /config 更新源列表
  Future<void> updateSourceBeansFromSpiderConfig(
    Map<String, dynamic> config,
    String spiderUrl,
  ) async {
    final video = config['video'] as Map<String, dynamic>?;
    final sites = video?['sites'] as List<dynamic>?;
    if (video == null || sites == null) {
      print('[ApiConfig] Spider /config 响应中没有 video.sites');
      return;
    }

    final newSources = <SourceBean>[];
    for (final site in sites) {
      final s = site as Map<String, dynamic>;
      var key = (s['key'] as String? ?? '').replaceAll('nodejs_', '');
      final name = s['name'] as String? ?? key;
      final api = s['api'] as String? ?? '';
      // 对应 Swift: as? Int ?? 1 - 使用安全转换避免 double/String 类型崩溃
      final type = _safeParseInt(s['type'], 3);
      final searchable = _safeParseInt(s['searchable'], 1);
      final filterable = _safeParseInt(s['filterable'], 1);
      final quickSearch = _safeParseInt(s['quickSearch'], 0);
      final playerType = _safeParseInt(s['playerType'], 0);
      final indexs = _safeParseInt(s['indexs'], 0);

      if (key.isEmpty) continue;

      newSources.add(SourceBean(
        key: key,
        name: name,
        api: api,
        searchable: searchable,
        filterable: filterable,
        quickSearch: quickSearch,
        playerType: playerType,
        type: type,
        ext: null,
        indexs: indexs,
      ));
    }

    if (newSources.isEmpty) {
      print('[ApiConfig] Spider /config 返回的 sites 为空');
      return;
    }

    sourceBeanList.value = newSources;

    // 关键修复：当前 homeSourceBean 可能是之前 _createSpiderSourceConfig
    // 临时创建的**占位 SourceBean**（基于 .js URL 派生），它的 key 不在
    // newSources 中。必须把 homeSourceBean 重置到新列表的真实第一项，
    // 否则用户在 PopupMenu 中看到的就是"基于源地址的占位线路"。
    final currentKey = homeSourceBean.value?.key;
    final isCurrentInNewList =
        currentKey != null && newSources.any((s) => s.key == currentKey);

    // 优先恢复保存的主页源
    await _restoreHomeSource(newSources);

    if (!isCurrentInNewList) {
      // 当前 homeSourceBean 是过时占位（key 不在新列表中），重置为新列表第一项
      homeSourceBean.value = newSources
              .where((s) => s.isSupportedInSwift)
              .firstOrNull ??
          newSources.firstOrNull;
    } else if (homeSourceBean.value == null) {
      // _restoreHomeSource 也没找到（保存的 key 在新列表中不存在），
      // 兜底选第一个支持的
      homeSourceBean.value = newSources
              .where((s) => s.isSupportedInSwift)
              .firstOrNull ??
          newSources.firstOrNull;
    }

    print('[ApiConfig] 从 Spider /config 更新了 ${newSources.length} 个线路，默认 homeSourceBean=${homeSourceBean.value?.key}');
  }

  // ============================================================
  // 配置获取（递归多仓库解析）
  // ============================================================

  Future<({AppConfigData config, String loadedFrom})> _fetchConfig(
    String apiUrl, {
    Set<String>? visitedUrls,
    int depth = 0,
  }) async {
    visitedUrls ??= {};

    if (depth > _maxConfigResolveDepth) {
      throw ConfigError.parseError.message('配置跳转层级过深（超过 $_maxConfigResolveDepth 层）');
    }

    final normalizedUrl = normalizeConfigUrl(apiUrl);
    if (normalizedUrl.isEmpty) {
      throw ConfigError.parseError.message('配置地址为空');
    }

    if (_isSpiderSourceUrl(normalizedUrl)) {
      final config = _createSpiderSourceConfig(normalizedUrl);
      return (config: config, loadedFrom: normalizedUrl);
    }

    final visitKey = normalizedUrl.toLowerCase();
    if (visitedUrls.contains(visitKey)) {
      throw ConfigError.parseError.message('检测到循环引用的配置地址: $normalizedUrl');
    }

    final nextVisited = Set<String>.from(visitedUrls);
    nextVisited.add(visitKey);

    final jsonStr = await _fetchConfigText(normalizedUrl);
    final cleanedJson = stripJsonComments(jsonStr);

    Map<String, dynamic>? decoded;
    try {
      decoded = jsonDecode(cleanedJson) as Map<String, dynamic>?;
    } catch (_) {}

    // 尝试作为正常配置解析
    if (decoded != null) {
      final config = AppConfigData.fromJson(decoded);
      if (config.hasUsableContent) {
        return (config: config, loadedFrom: normalizedUrl);
      }

      // 尝试多仓库
      try {
        final multiRepo = MultiRepoConfigData.fromJson(decoded);
        final candidateUrls = _uniqueUrlsInOrder(
          multiRepo.candidateUrls.map(normalizeConfigUrl).toList(),
        );

        Object? lastError;
        for (final candidateUrl in candidateUrls) {
          try {
            return await _fetchConfig(
              candidateUrl,
              visitedUrls: nextVisited,
              depth: depth + 1,
            );
          } catch (e) {
            lastError = e;
          }
        }

        if (lastError != null) {
          throw ConfigError.parseError.message(
            '多仓库配置中没有可用地址，最后错误: $lastError',
          );
        }
        throw ConfigError.parseError.message('多仓库配置中没有可用地址');
      } catch (e) {
        if (e is String && e.contains('配置解析错误')) rethrow;
        // 不是多仓库格式，继续尝试其他方式
      }

      // 尝试从页面中提取配置跳转候选
      final redirectCandidates = _extractConfigRedirectCandidates(cleanedJson)
          .where((c) => c.toLowerCase() != visitKey && !nextVisited.contains(c.toLowerCase()))
          .toList();

      if (redirectCandidates.isNotEmpty) {
        Object? lastError;
        for (final candidate in redirectCandidates) {
          try {
            return await _fetchConfig(
              candidate,
              visitedUrls: nextVisited,
              depth: depth + 1,
            );
          } catch (e) {
            lastError = e;
          }
        }

        if (lastError != null) {
          throw ConfigError.parseError.message(
            '页面跳转配置解析失败，最后错误: $lastError',
          );
        }
      }

      // 解码成功但缺少可用内容
      throw ConfigError.parseError.message('配置缺少可用站点（sites / lives / parses）');
    }

    throw ConfigError.parseError.message('配置格式不受支持');
  }

  /// 读取配置文本并做短时缓存
  Future<String> _fetchConfigText(String normalizedUrl) async {
    final key = normalizedUrl.toLowerCase();
    final now = DateTime.now();

    if (_rawConfigCache.containsKey(key)) {
      final entry = _rawConfigCache[key]!;
      if (now.difference(entry.fetchedAt).inSeconds <= _rawConfigCacheTTL) {
        return entry.content;
      }
      _rawConfigCache.remove(key);
    }

    final content = await _network.getString(normalizedUrl);
    _rawConfigCache[key] = _RawConfigCacheEntry(content: content, fetchedAt: now);
    _trimRawConfigCacheIfNeeded();
    return content;
  }

  void _trimRawConfigCacheIfNeeded() {
    if (_rawConfigCache.length <= _maxRawConfigCacheEntries) return;
    final overflow = _rawConfigCache.length - _maxRawConfigCacheEntries;
    final staleKeys = _rawConfigCache.entries
        .toList()
      ..sort((a, b) => a.value.fetchedAt.compareTo(b.value.fetchedAt));
    for (var i = 0; i < overflow && i < staleKeys.length; i++) {
      _rawConfigCache.remove(staleKeys[i].key);
    }
  }

  // ============================================================
  // 配置解析
  // ============================================================

  Future<void> _parseConfig(
    AppConfigData config, {
    required String apiUrl,
    required bool includeSources,
    required bool includeLive,
    required int loadToken,
  }) async {
    if (_activeLoadToken != loadToken) return;

    if (includeSources) {
      // 解析站点列表
      final sources = <SourceBean>[];
      if (config.sites != null) {
        for (final site in config.sites!) {
          sources.add(SourceBean(
            key: site.key ?? '',
            name: site.name ?? '未命名',
            api: site.api ?? '',
            searchable: site.searchable?.value ?? 1,
            filterable: site.filterable?.value ?? 1,
            quickSearch: site.quickSearch?.value ?? 0,
            playerType: site.playerType?.value ?? 0,
            type: site.type?.value ?? 1,
            ext: site.ext?.stringValue,
            indexs: site.indexs?.value ?? 0,
          ));
        }
      }
      sourceBeanList.value = sources;

      // 关键修复：如果当前解析结果包含 Spider 源（type=3），
      // 那么 sources 列表里那个 SourceBean 是 _createSpiderSourceConfig
      // 基于 .js URL 派生的**占位** SourceBean（name='Spider源(host)'），
      // 真正的站点列表需要等 NodeJS 启动 + getCatConfig 后才会出现。
      // 此处**不**把占位 SourceBean 设为 homeSourceBean，避免
      // PopupMenu 显示"基于源地址的占位线路"。等 updateSourceBeansFromSpiderConfig
      // 在 _fetchSpiderConfig 完成后用真实 sites 列表重置 homeSourceBean。
      final hasSpiderSource = sources.any((s) => s.isSpiderSource);
      if (hasSpiderSource) {
        print('[ApiConfig] 当前 config 含 Spider 源，homeSourceBean 等待 getCatConfig 完成后设置');
      } else {
        // 普通源：按优先级选第一个
        await _restoreHomeSource(sources);
        if (homeSourceBean.value == null) {
          homeSourceBean.value = sources
                  .where((s) => !s.isSpiderSource && s.isSupportedInSwift)
                  .firstOrNull ??
              sources.where((s) => !s.isSpiderSource).firstOrNull ??
              sources.where((s) => s.isSupportedInSwift).firstOrNull ??
              sources.firstOrNull;
        }
      }

      // 解析解析器列表
      if (config.parses != null) {
        parseBeanList.value = config.parses!
            .map((p) => ParseBean(name: p.name ?? '', url: p.url ?? '', type: p.type?.value ?? 0))
            .toList();
      } else {
        parseBeanList.value = [];
      }

      // 解析 DoH 列表
      if (config.doh != null) {
        dohList.value = config.doh!
            .where((d) => d.name != null && d.url != null)
            .map((d) => (d.name!, d.url!))
            .toList();
      } else {
        dohList.value = [];
      }

      // 壁纸
      wallpaper.value = config.wallpaper ?? '';
    }

    if (includeLive) {
      if (config.lives != null) {
        final parsedGroups = await _parseLives(
          config.lives!,
          apiUrl: apiUrl,
          loadToken: loadToken,
        );
        if (_activeLoadToken != loadToken) return;
        liveChannelGroupList.value = parsedGroups;
      } else {
        liveChannelGroupList.value = [];
      }
    }
  }

  Future<void> _restoreHomeSource(List<SourceBean> sources) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(AppConstants.homeApi);
      if (saved != null) {
        final found = sources.where((s) => s.key == saved).firstOrNull;
        if (found != null) {
          homeSourceBean.value = found;
          return;
        }
      }
    } catch (_) {}
  }

  // ============================================================
  // 直播解析
  // ============================================================

  Future<List<LiveChannelGroup>> _parseLives(
    List<LiveConfig> lives, {
    required String apiUrl,
    required int loadToken,
  }) async {
    final mergedGroups = <String, LiveChannelGroup>{};
    final remoteLiveTargets = <(int order, String url)>[];

    for (var index = 0; index < lives.length; index++) {
      final live = lives[index];
      if (_activeLoadToken != loadToken) return [];

      // 如果有 url，从远程加载
      if (live.url != null && live.url!.trim().isNotEmpty) {
        final resolvedUrl = _resolveLiveUrl(live.url!, baseConfigUrl: apiUrl);
        remoteLiveTargets.add((index, resolvedUrl));
      }

      // 如果有内嵌频道
      if (live.channels != null) {
        final inlineGroups = _parseInlineLiveChannels(live.channels!);
        _mergeLiveGroups(inlineGroups, mergedGroups);
      }
    }

    if (remoteLiveTargets.isNotEmpty) {
      // 并发加载远程直播源
      final futures = <Future<(int order, String content)>>[];
      for (final target in remoteLiveTargets) {
        futures.add(
          _network.getString(target.$2).then((content) => (target.$1, content)).catchError((e) {
            print('加载直播源失败: ${target.$2}, error: $e');
            return (target.$1, '');
          }),
        );
      }

      final fetchedContents = await Future.wait(futures);
      fetchedContents.sort((a, b) => a.$1.compareTo(b.$1));

      for (final (_, content) in fetchedContents) {
        if (_activeLoadToken != loadToken) return [];
        if (content.isEmpty) continue;
        final groups = parseLiveContent(content);
        _mergeLiveGroups(groups, mergedGroups);
        liveChannelGroupList.value = _sortedGroups(mergedGroups);
      }
    }

    return _sortedGroups(mergedGroups);
  }

  List<LiveChannelGroup> _parseInlineLiveChannels(
    List<LiveChannelConfig> channels,
  ) {
    final groups = <String, LiveChannelGroup>{};
    for (final channel in channels) {
      _appendChannel(
        channelName: channel.name ?? '',
        urls: channel.urls ?? [],
        logo: channel.logo ?? '',
        groupName: channel.group ?? '其他',
        groups: groups,
      );
    }
    return _sortedGroups(groups);
  }

  void _mergeLiveGroups(
    List<LiveChannelGroup> incomingGroups,
    Map<String, LiveChannelGroup> groups,
  ) {
    for (final group in incomingGroups) {
      for (final channel in group.channels) {
        _appendChannel(
          channelName: channel.channelName,
          urls: channel.channelUrls,
          logo: channel.logo,
          groupName: group.groupName,
          groups: groups,
        );
      }
    }
  }

  /// 解析 M3U / TXT 格式的直播内容
  List<LiveChannelGroup> parseLiveContent(String content) {
    final groups = <String, LiveChannelGroup>{};
    var currentGroupName = '默认';

    final lines = content.split(RegExp(r'\r?\n'));
    final firstNonEmpty = lines.firstWhere(
      (l) => l.trim().isNotEmpty,
      orElse: () => '',
    );
    final isM3U = firstNonEmpty.toUpperCase().startsWith('#EXTM3U');

    if (isM3U) {
      var currentName = '';
      var currentGroup = '默认';

      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.startsWith('#EXTINF:')) {
          // 解析频道名
          final commaIndex = trimmed.lastIndexOf(',');
          if (commaIndex >= 0) {
            currentName = trimmed.substring(commaIndex + 1).trim();
          }
          currentGroup = '默认';
          final groupMatch = RegExp(r'group-title="([^"]*)"').firstMatch(trimmed);
          if (groupMatch != null) {
            currentGroup = groupMatch.group(1) ?? '默认';
          }
        } else if (_isLiveStreamUrl(trimmed)) {
          if (currentName.isNotEmpty) {
            _appendChannel(
              channelName: currentName,
              urls: [trimmed],
              logo: '',
              groupName: currentGroup,
              groups: groups,
            );
            currentName = '';
          }
        }
      }
    } else {
      // TXT 格式: 分组名,#genre#  或  频道名,url
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;

        if (trimmed.endsWith(',#genre#') || trimmed.endsWith('，#genre#')) {
          currentGroupName = trimmed
              .replaceAll(',#genre#', '')
              .replaceAll('，#genre#', '')
              .trim();
          continue;
        }

        final parts = trimmed.split(',');
        if (parts.length >= 2) {
          final name = parts[0].trim();
          final url = parts.sublist(1).join(',').trim();

          if (name.isNotEmpty && _isLiveStreamUrl(url)) {
            _appendChannel(
              channelName: name,
              urls: [url],
              logo: '',
              groupName: currentGroupName,
              groups: groups,
            );
          }
        }
      }
    }

    return _sortedGroups(groups);
  }

  void _appendChannel({
    required String channelName,
    required List<String> urls,
    required String logo,
    required String groupName,
    required Map<String, LiveChannelGroup> groups,
  }) {
    final normalizedName = _normalizeChannelName(channelName);
    if (normalizedName.isEmpty) return;

    final validUrls = _uniqueLiveUrls(urls);
    if (validUrls.isEmpty) return;

    final normalizedGroupName = _normalizeGroupName(groupName);
    if (!groups.containsKey(normalizedGroupName)) {
      groups[normalizedGroupName] = LiveChannelGroup(
        groupName: normalizedGroupName,
        groupIndex: groups.length,
        channels: [],
      );
    }

    final group = groups[normalizedGroupName]!;

    final existingIndex = group.channels.indexWhere(
      (ch) => _normalizeChannelName(ch.channelName) == normalizedName,
    );

    if (existingIndex >= 0) {
      final existing = group.channels[existingIndex];
      // 确保 channelUrls 是可变列表（默认 const [] 不可变）
      existing.channelUrls = List<String>.from(existing.channelUrls);
      final existingUrlSet = existing.channelUrls.map(_normalizeLiveUrl).toSet();
      for (final url in validUrls) {
        final normalizedUrl = _normalizeLiveUrl(url);
        if (!existingUrlSet.contains(normalizedUrl)) {
          existing.channelUrls.add(url);
          existingUrlSet.add(normalizedUrl);
        }
      }
      final trimmedLogo = logo.trim();
      if (existing.logo.isEmpty && trimmedLogo.isNotEmpty) {
        existing.logo = trimmedLogo;
      }
    } else {
      group.channels.add(LiveChannelItem(
        channelName: normalizedName,
        channelIndex: group.channels.length,
        channelUrls: List<String>.from(validUrls),
        logo: logo.trim(),
      ));
    }
  }

  List<LiveChannelGroup> _sortedGroups(Map<String, LiveChannelGroup> groups) {
    final sorted = groups.values.toList()
      ..sort((a, b) => a.groupIndex.compareTo(b.groupIndex));
    for (var i = 0; i < sorted.length; i++) {
      for (var j = 0; j < sorted[i].channels.length; j++) {
        sorted[i].channels[j].channelIndex = j;
      }
    }
    return sorted;
  }

  String _resolveLiveUrl(String urlString, {required String baseConfigUrl}) {
    final trimmed = urlString.trim();
    if (trimmed.isEmpty) return trimmed;
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.hasScheme) {
      return normalizeConfigUrl(trimmed);
    }
    final baseUri = Uri.tryParse(baseConfigUrl);
    if (baseUri == null) return trimmed;
    final resolved = baseUri.resolve(trimmed);
    return normalizeConfigUrl(resolved.toString());
  }

  List<String> _uniqueLiveUrls(List<String> urls) {
    final result = <String>[];
    final seen = <String>{};

    for (final url in urls) {
      final normalized = _normalizeLiveUrl(url);
      if (normalized.isEmpty || !_isLiveStreamUrl(normalized) || seen.contains(normalized)) {
        continue;
      }
      seen.add(normalized);
      result.add(normalized);
    }

    return result;
  }

  String _normalizeGroupName(String groupName) {
    final trimmed = groupName.trim();
    return trimmed.isEmpty ? '默认' : trimmed;
  }

  String _normalizeChannelName(String channelName) {
    return channelName.trim();
  }

  String _normalizeLiveUrl(String url) {
    return url.trim();
  }

  bool _isLiveStreamUrl(String url) {
    final lower = url.toLowerCase();
    return lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('rtmp://') ||
        lower.startsWith('rtsp://');
  }

  // ============================================================
  // URL 规范化（静态方法，与 Swift 一致）
  // ============================================================

  /// 统一规范配置 URL
  static String normalizeConfigUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return trimmed;

    final fixedScheme = _fixMalformedSchemeIfNeeded(trimmed);

    final normalizedProxy = _normalizeGhProxyWrappedUrl(fixedScheme);
    if (normalizedProxy != null) return normalizedProxy;

    final githubRaw = _convertGitHubBlobUrlToRaw(fixedScheme);
    if (githubRaw != null) return githubRaw;

    return fixedScheme;
  }

  static String _fixMalformedSchemeIfNeeded(String urlString) {
    var fixed = urlString.replaceFirst(RegExp(r'^https:/(?!/)'), 'https://');
    fixed = fixed.replaceFirst(RegExp(r'^http:/(?!/)'), 'http://');
    return fixed;
  }

  static String? _normalizeGhProxyWrappedUrl(String urlString) {
    final uri = Uri.tryParse(urlString);
    if (uri == null) return null;

    final host = uri.host.toLowerCase();
    if (!host.contains('gh-proxy')) return null;

    var path = uri.path;
    while (path.startsWith('/') && path.length > 1) {
      path = path.substring(1);
    }
    if (path.isEmpty) return null;

    final decodedPath = Uri.decodeFull(path);
    final fixedEmbedded = _fixMalformedSchemeIfNeeded(decodedPath);
    if (!fixedEmbedded.startsWith('http://') &&
        !fixedEmbedded.startsWith('https://')) {
      return null;
    }

    final normalizedEmbedded =
        _convertGitHubBlobUrlToRaw(fixedEmbedded) ?? fixedEmbedded;
    final scheme = uri.scheme.isEmpty ? 'https' : uri.scheme;
    final portSuffix = uri.hasPort ? ':${uri.port}' : '';

    var rebuilt = '$scheme://$host$portSuffix/$normalizedEmbedded';
    if (uri.hasQuery) rebuilt += '?${uri.query}';
    if (uri.hasFragment) rebuilt += '#${uri.fragment}';
    return rebuilt;
  }

  static String? _convertGitHubBlobUrlToRaw(String urlString) {
    final uri = Uri.tryParse(urlString);
    if (uri == null) return null;

    final host = uri.host.toLowerCase();
    if (host != 'github.com' && host != 'www.github.com') return null;

    final parts = uri.pathSegments;
    if (parts.length < 5 || parts[2] != 'blob') return null;

    final owner = parts[0];
    final repo = parts[1];
    final branch = parts[3];
    final filePath = parts.sublist(4).join('/');
    if (filePath.isEmpty) return null;

    var rawUrl = 'https://raw.githubusercontent.com/$owner/$repo/$branch/$filePath';
    if (uri.hasQuery) rawUrl += '?${uri.query}';
    if (uri.hasFragment) rawUrl += '#${uri.fragment}';
    return rawUrl;
  }

  static bool _isSpiderSourceUrl(String url) {
    final lower = url.toLowerCase();
    // 检查路径后缀
    final path = Uri.tryParse(lower)?.path ?? lower;
    return path.endsWith('.js') ||
        path.endsWith('.js.md5') ||
        path.endsWith('.jar') ||
        path.endsWith('.jar.md5');
  }

  static AppConfigData _createSpiderSourceConfig(String url) {
    final uri = Uri.tryParse(url);
    final pathSegments = uri?.pathSegments ?? [];

    String key;
    if (uri != null && uri.host.isNotEmpty && pathSegments.isNotEmpty) {
      final fileName = pathSegments.last
          .replaceAll('.js.md5', '')
          .replaceAll('.js', '')
          .replaceAll('.jar.md5', '')
          .replaceAll('.jar', '');
      key = fileName.isEmpty ? uri.host : fileName;
    } else if (uri != null && uri.host.isNotEmpty) {
      key = uri.host;
    } else {
      key = 'spider_source';
    }

    final name = (uri != null && uri.host.isNotEmpty)
        ? 'Spider源(${uri.host})'
        : 'Spider源';

    return AppConfigData(
      spider: url,
      sites: [
        SiteConfig(
          key: key,
          name: name,
          api: url,
          searchable: const FlexibleInt(1),
          filterable: const FlexibleInt(1),
          type: const FlexibleInt(3),
        ),
      ],
    );
  }

  // ============================================================
  // JSON 注释剥离
  // ============================================================

  /// 去除 JSON 中的 // 行注释，兼容 TVBox 配置文件格式
  static String stripJsonComments(String json) {
    final lines = json.split('\n');
    final result = <String>[];

    for (final line in lines) {
      final trimmed = line.trim();
      // 跳过纯注释行
      if (trimmed.startsWith('//')) continue;
      // 处理行尾注释
      result.add(_removeInlineComment(line));
    }

    var joined = result.join('\n');
    // 修复尾部逗号问题：,] 或 ,}
    joined = joined.replaceAll(RegExp(r',\s*([}\]])'), r'$1');
    return joined;
  }

  /// 移除行内注释（只处理不在字符串内的 //）
  static String _removeInlineComment(String line) {
    var inString = false;
    var escape = false;
    final chars = line.split('');

    for (var i = 0; i < chars.length; i++) {
      final c = chars[i];
      if (escape) {
        escape = false;
        continue;
      }
      if (c == '\\' && inString) {
        escape = true;
        continue;
      }
      if (c == '"') {
        inString = !inString;
        continue;
      }
      if (!inString && c == '/' && i + 1 < chars.length && chars[i + 1] == '/') {
        // 找到行内注释，截断
        final before = line.substring(0, i).trimRight();
        if (before.endsWith(',')) {
          return before.substring(0, before.length - 1);
        }
        return line.substring(0, i);
      }
    }
    return line;
  }

  // ============================================================
  // 配置跳转候选提取
  // ============================================================

  static List<String> _extractConfigRedirectCandidates(String content) {
    final trimmed = content.trim();
    final rawCandidates = <String>[];

    // 明文 URL（单行且以 http 开头）
    if ((trimmed.startsWith('http://') || trimmed.startsWith('https://')) &&
        !trimmed.contains('\n')) {
      rawCandidates.add(trimmed);
    }

    // data-clipboard-text
    rawCandidates.addAll(
      _matchCaptureGroup(r'data-clipboard-text\s*=\s*["\x27]([^"\x27]+)["\x27]', content),
    );

    // JSON 中的 url 字段
    rawCandidates.addAll(
      _matchCaptureGroup(r'"url"\s*:\s*"([^"]+)"', content),
    );

    // 通用 URL 匹配
    rawCandidates.addAll(
      _matchCaptureGroup(r'(https?://[^\s"\x27<>\\]+)', content),
    );

    final normalized = rawCandidates
        .map(_sanitizeExtractedUrl)
        .map(normalizeConfigUrl)
        .where((u) => u.isNotEmpty)
        .where(_isLikelyConfigPointerUrl)
        .where((u) => !_isLikelyBinaryAssetUrl(u))
        .toList();

    return _uniqueUrlsInOrder(normalized).take(_maxRedirectCandidates).toList();
  }

  static List<String> _matchCaptureGroup(String pattern, String content) {
    final regex = RegExp(pattern, caseSensitive: false);
    return regex.allMatches(content).map((m) => m.group(1) ?? '').where((s) => s.isNotEmpty).toList();
  }

  static String _sanitizeExtractedUrl(String value) {
    var result = value.trim();
    result = result.replaceAll('&amp;', '&');
    result = result.replaceAll('\\/', '/');

    // 移除尾部标点
    while (result.isNotEmpty && ['.', ',', ';', ')', ']', '}', '"', "'"].contains(result[result.length - 1])) {
      result = result.substring(0, result.length - 1);
    }
    // 移除首部标点
    while (result.isNotEmpty && ['"', "'", '(', '[', '{'].contains(result[0])) {
      result = result.substring(1);
    }

    return result.trim();
  }

  static bool _isLikelyBinaryAssetUrl(String urlString) {
    final uri = Uri.tryParse(urlString);
    if (uri == null) return false;
    final path = uri.path.toLowerCase();
    return path.endsWith('.png') ||
        path.endsWith('.jpg') ||
        path.endsWith('.jpeg') ||
        path.endsWith('.webp') ||
        path.endsWith('.gif') ||
        path.endsWith('.svg') ||
        path.endsWith('.ico') ||
        path.endsWith('.css') ||
        path.endsWith('.woff') ||
        path.endsWith('.woff2') ||
        path.endsWith('.ttf');
  }

  static bool _isLikelyConfigPointerUrl(String urlString) {
    final uri = Uri.tryParse(urlString);
    if (uri == null) return false;

    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    final query = uri.query.toLowerCase();

    if (host.contains('raw.githubusercontent.com') ||
        host.contains('githubusercontent.com')) {
      return true;
    }

    if (path.contains('.json') ||
        path.endsWith('/tv') ||
        path.endsWith('/tv/') ||
        path.endsWith('/m') ||
        path.endsWith('/m/') ||
        path.contains('tvbox') ||
        path.contains('box') ||
        query.contains('json') ||
        query.contains('config') ||
        query.contains('url=')) {
      return true;
    }

    return false;
  }

  static List<String> _uniqueUrlsInOrder(List<String> urls) {
    final seen = <String>{};
    final result = <String>[];

    for (final url in urls) {
      final trimmed = url.trim();
      if (trimmed.isEmpty) continue;
      final key = trimmed.toLowerCase();
      if (seen.contains(key)) continue;
      seen.add(key);
      result.add(trimmed);
    }

    return result;
  }
}

/// 原始配置缓存条目
class _RawConfigCacheEntry {
  final String content;
  final DateTime fetchedAt;

  _RawConfigCacheEntry({required this.content, required this.fetchedAt});
}
