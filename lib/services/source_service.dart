import 'dart:convert';
import '../models/movie.dart';
import '../models/vod_info.dart';
import '../models/source_bean.dart';
import '../models/movie_sort.dart';
import 'api_config.dart';
import 'spider_service.dart';
import 'network_manager.dart';

/// 源错误枚举
enum SourceError {
  emptyApi,
  parseError,
  unsupportedType,
  invalidApiUrl;

  String message([String? detail]) {
    switch (this) {
      case SourceError.emptyApi:
        return '接口地址为空';
      case SourceError.parseError:
        return '数据解析错误${detail != null ? ': $detail' : ''}';
      case SourceError.unsupportedType:
        return '暂不支持 ${detail ?? "未知"} 类型的数据源，请切换其他源';
      case SourceError.invalidApiUrl:
        return '无效的接口地址${detail != null ? ': $detail' : ''}';
    }
  }
}

/// 视频源数据服务 - 对应 Swift SourceService
/// 负责从各视频源获取分类、列表、详情和搜索数据
class SourceService {
  static final SourceService _instance = SourceService._internal();
  static SourceService get instance => _instance;
  SourceService._internal();

  final NetworkManager _network = NetworkManager.instance;

  // ============================================================
  // 获取分类列表
  // ============================================================

  /// 获取指定源的分类列表和首页推荐 - 对应 Swift getSort
  Future<(List<SortData> sorts, List<Video> homeVideos)> getSort(
      SourceBean sourceBean) async {
    final api = sourceBean.api;
    // 对应 Swift: Spider 源不需要检查 api 是否为空
    if (!sourceBean.isSpiderSource && api.isEmpty) {
      throw Exception(SourceError.emptyApi.message());
    }

    if (sourceBean.isSpiderSource) {
      return _getSpiderSort(sourceBean);
    }

    if (!sourceBean.isSupportedInSwift) {
      throw Exception(
          SourceError.unsupportedType.message(sourceBean.typeDescription));
    }

    if (!sourceBean.isHttpApi) {
      throw Exception(SourceError.invalidApiUrl.message(api));
    }

    String jsonStr;
    if (sourceBean.type == 0) {
      // XML 接口
      jsonStr = await _network.getString(api);
    } else if (sourceBean.type == 4) {
      // Type 4: 远程接口，需要 extend 和 filter 参数
      final queryParams = <String, String>{'filter': 'true'};
      final ext = sourceBean.ext;
      if (ext != null && ext.isNotEmpty) {
        final extend = await _resolveExtend(ext);
        if (extend.isNotEmpty) queryParams['extend'] = extend;
      }
      jsonStr =
          await _network.getString(_buildURL(api, queryParams));
    } else {
      // JSON 接口 (type=1)
      jsonStr = await _network
          .getString(_buildURL(api, {'ac': 'class'}));
    }

    var result = _parseSort(jsonStr, sourceBean: sourceBean);

    // 当大多数推荐视频的 vod_pic 为空时，额外请求列表接口获取带完整海报的推荐视频
    final picMissingCount =
        result.$2.where((v) => v.pic.trim().isEmpty).length;
    final needsFallback =
        result.$2.isEmpty || picMissingCount > result.$2.length ~/ 2;

    if (needsFallback &&
        (sourceBean.type == 1 || sourceBean.type == 4)) {
      final listUrl = sourceBean.type == 4
          ? _buildURL(api, {
              'ac': 'detail',
              'filter': 'true',
              'pg': '1',
              'ext': base64Encode(utf8.encode('{}')),
            })
          : _buildURL(api, {'ac': 'videolist', 'pg': '1'});

      try {
        final listStr = await _network.getString(listUrl);
        final fallback = _parseVideoList(listStr,
            sourceKey: sourceBean.key, type: sourceBean.type);
        if (fallback.isNotEmpty) {
          result = (result.$1, fallback);
        }
      } catch (_) {}
    }

    return result;
  }

  (List<SortData> sorts, List<Video> homeVideos) _parseSort(String jsonStr,
      {required SourceBean sourceBean}) {
    List<SortData> sorts = [];
    List<Video> homeVideos = [];

    if (sourceBean.type == 0) {
      sorts = _parseXMLCategories(jsonStr);
    } else {
      try {
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;

        // 解析筛选条件
        final filtersMap = _parseFilters(json['filters']);

        // 解析分类
        if (json['class'] != null) {
          for (final cls in json['class'] as List<dynamic>) {
            final c = cls as Map<String, dynamic>;
            final id = c['type_id'] is int
                ? c['type_id'].toString()
                : c['type_id'] as String? ?? '';
            final name = c['type_name'] as String? ?? '';
            sorts.add(SortData(
              id: id,
              name: name,
              filters: filtersMap[id] ?? [],
            ));
          }
        }

        // 解析首页推荐视频
        homeVideos = _parseVideoListFromJson(
            json['list'], sourceBean.key);
      } catch (_) {}
    }

    return (sorts, homeVideos);
  }

  /// 解析 filters 字段
  Map<String, List<SortFilter>> _parseFilters(dynamic filtersData) {
    final filtersMap = <String, List<SortFilter>>{};
    if (filtersData == null) return filtersMap;

    final filters = filtersData as Map<String, dynamic>;
    for (final entry in filters.entries) {
      final typeId = entry.key;
      final filterList = entry.value as List<dynamic>;
      final parsedFilters = <SortFilter>[];
      for (final filter in filterList) {
        final f = filter as Map<String, dynamic>;
        final key = f['key'] as String? ?? '';
        final name = f['name'] as String? ?? key;
        final values = <SortFilterValue>[];
        if (f['value'] != null) {
          for (final v in f['value'] as List<dynamic>) {
            final vv = v as Map<String, dynamic>;
            final n = vv['n'] as String? ?? '';
            final val = vv['v'] as String? ?? '';
            if (n.isNotEmpty || val.isNotEmpty) {
              values.add(SortFilterValue(n: n, v: val));
            }
          }
        }
        if (key.isNotEmpty) {
          parsedFilters.add(SortFilter(key: key, name: name, values: values));
        }
      }
      filtersMap[typeId] = parsedFilters;
    }
    return filtersMap;
  }

  List<SortData> _parseXMLCategories(String xml) {
    final sorts = <SortData>[];
    final regex = RegExp(r'<ty id="(\d+)"[^>]*>([^<]+)</ty>');
    for (final match in regex.allMatches(xml)) {
      sorts.add(SortData(
          id: match.group(1) ?? '', name: match.group(2) ?? ''));
    }
    return sorts;
  }

  // ============================================================
  // 获取分类视频列表
  // ============================================================

  /// 获取分类视频列表 - 对应 Swift getList
  Future<List<Video>> getList(
    SourceBean sourceBean,
    SortData sortData, {
    int page = 1,
    Map<String, String>? filters,
  }) async {
    final api = sourceBean.api;
    // 对应 Swift: Spider 源不需要检查 api 是否为空
    if (!sourceBean.isSpiderSource && api.isEmpty) {
      throw Exception(SourceError.emptyApi.message());
    }

    if (sourceBean.isSpiderSource) {
      return _getSpiderList(sourceBean, sortData,
          page: page, filters: filters);
    }

    if (!sourceBean.isSupportedInSwift) {
      throw Exception(
          SourceError.unsupportedType.message(sourceBean.typeDescription));
    }

    if (!sourceBean.isHttpApi) {
      throw Exception(SourceError.invalidApiUrl.message(api));
    }

    String url;
    if (sourceBean.type == 0) {
      // XML 接口
      url = _buildURL(api, {
        'ac': 'videolist',
        't': sortData.id,
        'pg': page.toString(),
      });
    } else if (sourceBean.type == 4) {
      // Type 4: 远程接口
      final queryParams = <String, String>{
        'ac': 'detail',
        'filter': 'true',
        't': sortData.id,
        'pg': page.toString(),
      };

      // 附加筛选参数（base64 编码）
      if (filters != null && filters.isNotEmpty) {
        final filterStr = jsonEncode(filters);
        queryParams['ext'] = base64Encode(utf8.encode(filterStr));
      } else {
        queryParams['ext'] = base64Encode(utf8.encode('{}'));
      }

      // 加载 extend
      final ext = sourceBean.ext;
      if (ext != null && ext.isNotEmpty) {
        final extend = await _resolveExtend(ext);
        if (extend.isNotEmpty) queryParams['extend'] = extend;
      }
      url = _buildURL(api, queryParams);
    } else {
      // JSON 接口 (type=1)
      final queryParams = <String, String>{
        'ac': 'videolist',
        't': sortData.id,
        'pg': page.toString(),
      };

      // 附加筛选参数
      if (filters != null) {
        queryParams.addAll(filters);
      }
      url = _buildURL(api, queryParams);
    }

    final jsonStr = await _network.getString(url);
    return _parseVideoList(jsonStr,
        sourceKey: sourceBean.key, type: sourceBean.type);
  }

  List<Video> _parseVideoList(String jsonStr,
      {required String sourceKey, required int type}) {
    final videos = <Video>[];

    if (type == 0) {
      return _parseXMLVideoList(jsonStr, sourceKey: sourceKey);
    }

    try {
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      videos.addAll(_parseVideoListFromJson(json['list'], sourceKey));
    } catch (_) {}

    return videos;
  }

  /// 从 JSON list 字段解析视频列表
  List<Video> _parseVideoListFromJson(
      dynamic listData, String sourceKey) {
    final videos = <Video>[];
    if (listData == null) return videos;

    for (final item in listData as List<dynamic>) {
      try {
        var video = Video.fromJson(item as Map<String, dynamic>);
        video = Video(
          id: video.id,
          name: video.name,
          pic: video.pic,
          note: video.note,
          year: video.year,
          area: video.area,
          type: video.type,
          director: video.director,
          actor: video.actor,
          des: video.des,
          sourceKey: sourceKey,
          tid: video.tid,
          last: video.last,
          dt: video.dt,
        );
        videos.add(video);
      } catch (_) {}
    }
    return videos;
  }

  List<Video> _parseXMLVideoList(String xml, {required String sourceKey}) {
    final videos = <Video>[];
    final regex = RegExp(
        r'<video>.*?<id>(\d+)</id>.*?<name><!\[CDATA\[(.+?)\]\]></name>.*?<pic>(.*?)</pic>.*?<note><!\[CDATA\[(.*?)\]\]></note>.*?</video>',
        dotAll: true);
    for (final match in regex.allMatches(xml)) {
      videos.add(Video(
        id: match.group(1) ?? '',
        name: match.group(2) ?? '',
        pic: match.group(3) ?? '',
        note: match.group(4) ?? '',
        sourceKey: sourceKey,
      ));
    }
    return videos;
  }

  // ============================================================
  // 获取详情
  // ============================================================

  /// 获取视频详情 - 对应 Swift getDetail
  Future<VodInfo?> getDetail(SourceBean sourceBean, String vodId) async {
    final api = sourceBean.api;
    // 对应 Swift: Spider 源不需要检查 api 是否为空
    if (!sourceBean.isSpiderSource && api.isEmpty) {
      throw Exception(SourceError.emptyApi.message());
    }

    if (sourceBean.isSpiderSource) {
      return _getSpiderDetail(sourceBean, vodId);
    }

    if (!sourceBean.isSupportedInSwift) {
      throw Exception(
          SourceError.unsupportedType.message(sourceBean.typeDescription));
    }

    if (!sourceBean.isHttpApi) {
      throw Exception(SourceError.invalidApiUrl.message(api));
    }

    String url;
    if (sourceBean.type == 0) {
      url = _buildURL(api, {'ac': 'videolist', 'ids': vodId});
    } else if (sourceBean.type == 4) {
      // Type 4: 远程接口
      final queryParams = <String, String>{
        'ac': 'detail',
        'ids': vodId,
      };

      // 加载 extend
      final ext = sourceBean.ext;
      if (ext != null && ext.isNotEmpty) {
        final extend = await _resolveExtend(ext);
        if (extend.isNotEmpty) queryParams['extend'] = extend;
      }
      url = _buildURL(api, queryParams);
    } else {
      // JSON 接口 (type=1)
      url = _buildURL(api, {'ac': 'detail', 'ids': vodId});
    }

    final jsonStr = await _network.getString(url);
    return _parseDetail(jsonStr,
        sourceKey: sourceBean.key, type: sourceBean.type);
  }

  VodInfo? _parseDetail(String jsonStr,
      {required String sourceKey, required int type}) {
    if (type == 0) return _parseXMLDetail(jsonStr, sourceKey: sourceKey);

    try {
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final list = json['list'] as List<dynamic>?;
      if (list == null || list.isEmpty) return null;

      final first = list.first as Map<String, dynamic>;
      var video = Video.fromJson(first);
      video = Video(
        id: video.id,
        name: video.name,
        pic: video.pic,
        note: video.note,
        year: video.year,
        area: video.area,
        type: video.type,
        director: video.director,
        actor: video.actor,
        des: video.des,
        sourceKey: sourceKey,
        tid: video.tid,
        last: video.last,
        dt: video.dt,
      );

      final playFrom = first['vod_play_from'] as String? ?? '';
      final playUrl = first['vod_play_url'] as String? ?? '';

      return VodInfo.fromVideo(
        video: video,
        playFrom: playFrom,
        playUrl: playUrl,
      );
    } catch (_) {
      return null;
    }
  }

  // ============================================================
  // 搜索
  // ============================================================

  /// 在指定源中搜索 - 对应 Swift search
  Future<List<Video>> search(SourceBean sourceBean, String keyword) async {
    final api = sourceBean.api;
    // 对应 Swift: Spider 源不需要检查 api 是否为空
    if (!sourceBean.isSpiderSource && api.isEmpty) {
      throw Exception(SourceError.emptyApi.message());
    }

    if (sourceBean.isSpiderSource) {
      return _spiderSearch(sourceBean, keyword);
    }

    if (!sourceBean.isSupportedInSwift) {
      throw Exception(
          SourceError.unsupportedType.message(sourceBean.typeDescription));
    }

    if (!sourceBean.isHttpApi) {
      throw Exception(SourceError.invalidApiUrl.message(api));
    }

    String url;
    if (sourceBean.type == 0) {
      url = _buildURL(api, {'wd': keyword});
    } else if (sourceBean.type == 4) {
      // Type 4: 远程接口
      final quickValue =
          sourceBean.isQuickSearchEnabled ? 'true' : 'false';
      final queryParams = <String, String>{
        'wd': keyword,
        'ac': 'detail',
        'quick': quickValue,
      };

      // 加载 extend
      final ext = sourceBean.ext;
      if (ext != null && ext.isNotEmpty) {
        final extend = await _resolveExtend(ext);
        if (extend.isNotEmpty) queryParams['extend'] = extend;
      }
      url = _buildURL(api, queryParams);
    } else {
      // JSON 接口 (type=1)
      url = _buildURL(api, {'wd': keyword});
    }

    final jsonStr = await _network.getString(url);
    final videos = _parseVideoList(jsonStr,
        sourceKey: sourceBean.key, type: sourceBean.type);
    return _filterSearchResults(videos, keyword: keyword);
  }

  /// 多源并发搜索 - 对应 Swift searchAll
  Future<List<Video>> searchAll(String keyword) async {
    final sources = ApiConfig.instance.getSearchableSources();
    final validSources =
        sources.where((s) => s.isSupportedInSwift).toList();

    final allResults = <Video>[];
    final futures = <Future<List<Video>>>[];

    for (final source in validSources) {
      futures
          .add(search(source, keyword).catchError((_) => <Video>[]));
    }

    final results = await Future.wait(futures);
    for (final videos in results) {
      allResults.addAll(videos);
    }

    return allResults;
  }

  /// 对源返回结果做本地关键词过滤，规避部分接口返回推荐/无关内容
  List<Video> _filterSearchResults(List<Video> videos,
      {required String keyword}) {
    final tokens = keyword
        .split(RegExp(r'\s+'))
        .map((t) => _normalizeSearchText(t))
        .where((t) => t.isNotEmpty)
        .toList();

    if (tokens.isEmpty) return videos;

    return videos.where((video) {
      final searchableText = _normalizeSearchText([
        video.name,
        video.note,
        video.actor,
        video.director,
        video.type,
        video.area,
        video.year,
      ].join(' '));
      if (searchableText.isEmpty) return false;
      return tokens.every((token) => searchableText.contains(token));
    }).toList();
  }

  /// 规范化搜索文本：移除标点、空白，转小写
  String _normalizeSearchText(String text) {
    final cleaned = text
        .replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '')
        .toLowerCase();
    return cleaned;
  }

  // ============================================================
  // Extend 解析
  // ============================================================

  /// 解析 extend 参数 - 对应 Swift resolveExtend
  Future<String> _resolveExtend(String extend) async {
    if (extend.isEmpty) return '';

    // 非 HTTP URL 直接返回
    if (!extend.startsWith('http://') &&
        !extend.startsWith('https://')) {
      return extend;
    }

    // 从 HTTP URL 加载 extend 内容
    try {
      final content = await _network.getString(extend);
      final trimmed = content.trim();
      // 如果内容过长（>2500），回退到使用原始 URL
      if (trimmed.length > 2500) return extend;
      return trimmed;
    } catch (_) {
      return extend;
    }
  }

  // ============================================================
  // XML 解析
  // ============================================================

  VodInfo? _parseXMLDetail(String xml, {required String sourceKey}) {
    final videoBlock =
        RegExp(r'<video[\s\S]*?</video>').firstMatch(xml);
    if (videoBlock == null) return null;

    final block = videoBlock.group(0)!;
    final vodId = _extractXMLTag('id', block);
    if (vodId.isEmpty) return null;

    final video = Video(
      id: vodId,
      name: _extractXMLTag('name', block),
      pic: _extractXMLTag('pic', block),
      note: _extractXMLTag('note', block),
      year: _extractXMLTag('year', block),
      area: _extractXMLTag('area', block),
      type: _extractXMLTag('type', block),
      director: _extractXMLTag('director', block),
      actor: _extractXMLTag('actor', block),
      des: _extractXMLTag('des', block),
      sourceKey: sourceKey,
    );

    // 解析 XML 的 dd 节点获取播放线路
    final ddNodes = _extractXMLDDNodes(block);
    final playFrom = ddNodes.isEmpty
        ? '默认'
        : ddNodes.map((n) => n.$1).join('\$\$\$');
    final playUrl =
        ddNodes.isEmpty ? '' : ddNodes.map((n) => n.$2).join('\$\$\$');

    return VodInfo.fromVideo(
        video: video, playFrom: playFrom, playUrl: playUrl);
  }

  List<(String, String)> _extractXMLDDNodes(String block) {
    final regex =
        RegExp(r'<dd([^>]*)>([\s\S]*?)</dd>', caseSensitive: false);
    final result = <(String, String)>[];

    for (final match in regex.allMatches(block)) {
      if (match.groupCount < 2) continue;
      final attrs = match.group(1) ?? '';
      final rawUrl = _decodeXMLText(match.group(2) ?? '');
      if (rawUrl.isEmpty) continue;

      final flagMatch =
          RegExp(r'''flag\s*=\s*["']([^"']+)["']''').firstMatch(attrs);
      final flag = flagMatch != null
          ? _decodeXMLText(flagMatch.group(1)!)
          : '线路${result.length + 1}';
      result.add((flag, rawUrl));
    }

    return result;
  }

  String _extractXMLTag(String tag, String content) {
    final escapedTag = RegExp.escape(tag);
    final regex = RegExp('<$escapedTag>\\s*([\\s\\S]*?)\\s*</$escapedTag>',
        caseSensitive: false);
    final match = regex.firstMatch(content);
    final value = match?.group(1) ?? '';
    return _decodeXMLText(value);
  }

  String _decodeXMLText(String raw) {
    var value = raw.trim();
    if (value.startsWith('<![CDATA[') &&
        value.endsWith(']]>') &&
        value.length >= 12) {
      value = value.substring(9, value.length - 3);
    }
    value = value.replaceAll('&amp;', '&');
    value = value.replaceAll('&lt;', '<');
    value = value.replaceAll('&gt;', '>');
    value = value.replaceAll('&quot;', '"');
    value = value.replaceAll('&#39;', "'");
    return value.trim();
  }

  // ============================================================
  // URL 构建
  // ============================================================

  String _buildURL(String base, Map<String, String> queryItems) {
    final trimmedBase = base.trim();
    final uri = Uri.tryParse(trimmedBase);
    if (uri == null) {
      throw Exception(SourceError.invalidApiUrl.message(base));
    }

    final existingParams = uri.queryParameters;
    final mergedParams = {...existingParams, ...queryItems};
    return uri.replace(queryParameters: mergedParams).toString();
  }

  // ============================================================
  // Spider API (type=3) - 对应 Swift Spider 相关方法
  // ============================================================

  /// 设置当前 Spider 并获取首页内容
  /// 对应 Swift getSpiderSort - 调用 setCurrentSpider 设置全局状态
  Future<(List<SortData>, List<Video>)> _getSpiderSort(
      SourceBean sourceBean) async {
    final spider = SpiderService.instance;

    // 对应 Swift: key 去掉 nodejs_ 前缀，apiBase 在 api 是 HTTP URL 时为空
    final key = sourceBean.key.startsWith('nodejs_')
        ? sourceBean.key.substring(7)
        : sourceBean.key;
    final apiBase =
        sourceBean.api.startsWith('http') ? '' : sourceBean.api;

    // 对应 Swift: setCurrentSpider 设置全局状态（供详情页 getPlayUrl 使用）
    spider.setCurrentSpider(key, sourceBean.type, apiBase,
        ext: sourceBean.ext, jar: sourceBean.jar);

    // 初始化 Spider - 对应 Swift: try await spider.initSpider()
    try {
      await spider.initSpider(key, sourceBean.type, apiBase);
    } catch (_) {}

    // 获取首页内容
    final result = await spider.getHomeContent(key, sourceBean.type, apiBase);
    if (result == null) return (<SortData>[], <Video>[]);

    final sorts = <SortData>[];
    final homeVideos = <Video>[];

    // 解析筛选条件
    final filtersMap = _parseFilters(result['filters']);

    // 解析分类
    if (result['class'] != null) {
      for (final cls in result['class'] as List<dynamic>) {
        final c = cls as Map<String, dynamic>;
        final id = c['type_id'] is int
            ? c['type_id'].toString()
            : c['type_id'] as String? ?? '';
        final name = c['type_name'] as String? ?? '';
        sorts.add(SortData(
            id: id, name: name, filters: filtersMap[id] ?? []));
      }
    }

    // 解析首页推荐视频
    homeVideos.addAll(
        _parseVideoListFromJson(result['list'], sourceBean.key));

    return (sorts, homeVideos);
  }

  /// 获取 Spider 分类视频列表
  /// 对应 Swift getSpiderList - 调用 setCurrentSpider 设置全局状态
  Future<List<Video>> _getSpiderList(
    SourceBean sourceBean,
    SortData sortData, {
    int page = 1,
    Map<String, String>? filters,
  }) async {
    final spider = SpiderService.instance;

    // 对应 Swift: key 去掉 nodejs_ 前缀，apiBase 在 api 是 HTTP URL 时为空
    final key = sourceBean.key.startsWith('nodejs_')
        ? sourceBean.key.substring(7)
        : sourceBean.key;
    final apiBase =
        sourceBean.api.startsWith('http') ? '' : sourceBean.api;

    // 对应 Swift: setCurrentSpider 设置全局状态
    spider.setCurrentSpider(key, sourceBean.type, apiBase,
        ext: sourceBean.ext, jar: sourceBean.jar);

    // 获取分类内容
    final result = await spider.getCategoryContent(
      key, sourceBean.type, apiBase,
      sortData.id,
      page: page,
      filters: filters?.map((k, v) => MapEntry(k, v)),
    );

    if (result == null) return [];

    return _parseVideoListFromJson(result['list'], sourceBean.key);
  }

  /// 获取 Spider 详情
  /// 对应 Swift getSpiderDetail - 调用 setCurrentSpider 设置全局状态
  Future<VodInfo?> _getSpiderDetail(
      SourceBean sourceBean, String vodId) async {
    final spider = SpiderService.instance;

    // 对应 Swift: key 去掉 nodejs_ 前缀，apiBase 在 api 是 HTTP URL 时为空
    final key = sourceBean.key.startsWith('nodejs_')
        ? sourceBean.key.substring(7)
        : sourceBean.key;
    final apiBase =
        sourceBean.api.startsWith('http') ? '' : sourceBean.api;

    // 对应 Swift: setCurrentSpider 设置全局状态（供详情页 getPlayUrl 使用）
    spider.setCurrentSpider(key, sourceBean.type, apiBase,
        ext: sourceBean.ext, jar: sourceBean.jar);

    // 获取详情 - 对应 Swift: getDetail 只发送 id
    final result = await spider.getDetail(key, sourceBean.type, apiBase, vodId);
    if (result == null) return null;

    final list = result['list'] as List<dynamic>?;
    if (list == null || list.isEmpty) return null;

    final first = list.first as Map<String, dynamic>;
    var video = Video.fromJson(first);
    video = Video(
      id: video.id,
      name: video.name,
      pic: video.pic,
      note: video.note,
      year: video.year,
      area: video.area,
      type: video.type,
      director: video.director,
      actor: video.actor,
      des: video.des,
      sourceKey: sourceBean.key,
      tid: video.tid,
      last: video.last,
      dt: video.dt,
    );

    final playFrom = first['vod_play_from'] as String? ?? '';
    final playUrl = first['vod_play_url'] as String? ?? '';

    return VodInfo.fromVideo(
        video: video, playFrom: playFrom, playUrl: playUrl);
  }

  /// Spider 搜索 - 对应 Swift spiderSearch
  /// 使用 searchWithSpider 原子操作，避免并发竞态条件
  Future<List<Video>> _spiderSearch(
      SourceBean sourceBean, String keyword) async {
    final spider = SpiderService.instance;

    // 对应 Swift: key 去掉 nodejs_ 前缀，apiBase 在 api 是 HTTP URL 时为空
    final key = sourceBean.key.startsWith('nodejs_')
        ? sourceBean.key.substring(7)
        : sourceBean.key;
    final apiBase =
        sourceBean.api.startsWith('http') ? '' : sourceBean.api;

    print('[SourceService] _spiderSearch: key=$key, type=${sourceBean.type}, apiBase=$apiBase, keyword=$keyword');

    // 对应 Swift searchWithSpider: 原子操作，先 init 再 search
    // 不依赖全局状态，避免并发搜索时竞态条件
    final result = await spider.searchWithSpider(
      spiderKey: key,
      spiderType: sourceBean.type,
      apiBase: apiBase,
      keyword: keyword,
    );
    if (result == null) {
      print('[SourceService] _spiderSearch: searchWithSpider 返回 null');
      return [];
    }

    final list = result['list'];
    print('[SourceService] _spiderSearch: 返回 list=${list is List ? list.length : list.runtimeType} items');
    return _parseVideoListFromJson(list, sourceBean.key);
  }
}
