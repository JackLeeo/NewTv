import 'dart:convert';
import 'package:dio/dio.dart';
import 'nodejs_manager.dart';

/// Spider 服务 - 对应 Swift SpiderService
/// 与本地 Node.js Spider 服务通信
///
/// 关键设计：所有方法都接受 key/type/apiBase 参数，不依赖全局状态
/// 这是因为搜索等操作是并发执行的，全局状态会导致竞态条件
class SpiderService {
  static final SpiderService _instance = SpiderService._internal();
  static SpiderService get instance => _instance;

  // 必须可重建：iOS 进入后台/锁屏时，系统的 socket 会被断开，
  // 不重建会导致切回前台后所有请求都失败（点击线路/视频无响应）
  late Dio _dio;

  SpiderService._internal() {
    _dio = _buildDio();
  }

  static Dio _buildDio() {
    return Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 60),
      receiveTimeout: const Duration(seconds: 60),
    ));
  }

  // ============================================================
  // Spider 端口（从 NodeJSManager 获取）
  // ============================================================

  int get _spiderPort => NodeJSManager.instance.spiderPort;

  bool get isSpiderReady => _spiderPort > 0;

  // ============================================================
  // 路径构建 - 对应 Swift buildSpiderPath
  // ============================================================

  /// 构建 Spider 请求路径
  /// 当 apiBase 不为空时，路径为 {apiBase}/{action}
  /// 当 apiBase 为空时，路径为 /{key}/{type}/{action}
  String _buildSpiderPath(String key, int type, String apiBase, String action) {
    if (apiBase.isNotEmpty) {
      return '$apiBase/$action';
    }
    return '/$key/$type/$action';
  }

  /// 构建完整的 Spider URL
  String _buildSpiderUrl(String key, int type, String apiBase, String action) {
    return 'http://127.0.0.1:$_spiderPort${_buildSpiderPath(key, type, apiBase, action)}';
  }

  // ============================================================
  // 核心 POST 请求 - 对应 Swift postJSON
  // ============================================================

  /// 发送 POST 请求到 Spider 服务 - 对应 Swift postJSON
  /// 使用 ResponseType.plain 手动解析 JSON，接受 200-299 状态码
  /// 关键：iOS 后台/锁屏切回前台时，dio 的 socket 可能处于半死状态（OS
  /// 已标记断开但 dio 还没收到 RST），第一次请求会失败；加 1 次重试可恢复
  static const int _maxPostRetries = 1;
  static const Duration _postRetryDelay = Duration(milliseconds: 300);

  Future<Map<String, dynamic>?> _postJSON(
    String url,
    Map<String, dynamic> body,
  ) async {
    for (var attempt = 0; attempt <= _maxPostRetries; attempt++) {
      try {
        final response = await _dio.post<String>(
          url,
          data: jsonEncode(body),
          options: Options(
            contentType: Headers.jsonContentType,
            responseType: ResponseType.plain,
          ),
        );

        final statusCode = response.statusCode ?? 0;
        final responseBody = response.data ?? '';

        // 对应 Swift: guard (200...299).contains(httpResponse.statusCode)
        if (statusCode >= 200 && statusCode <= 299) {
          try {
            final decoded = jsonDecode(responseBody);
            if (decoded is Map<String, dynamic>) {
              return decoded;
            } else if (decoded is List) {
              // 某些 Spider 响应可能返回数组，包装为对象
              return {'list': decoded};
            }
            print('[SpiderService] 响应不是JSON对象: $url, body类型=${decoded.runtimeType}');
            return null;
          } catch (e) {
            print('[SpiderService] JSON解析失败: $url, 错误=$e, body=${responseBody.length > 500 ? responseBody.substring(0, 500) : responseBody}');
            return null;
          }
        } else {
          print('[SpiderService] HTTP错误 $statusCode: $url, body=${responseBody.length > 500 ? responseBody.substring(0, 500) : responseBody}');
          return null;
        }
      } on DioException catch (e) {
        // iOS 后台/锁屏切回前台时，dio 的 socket 可能半死（OS 标记断开但
        // 没收到 RST），重试一次通常能恢复
        final isRetriable = e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.sendTimeout ||
            e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.unknown;
        if (attempt < _maxPostRetries && isRetriable) {
          print('[SpiderService] POST $url 第 ${attempt + 1} 次失败，${_postRetryDelay.inMilliseconds}ms 后重试: ${e.type}/${e.message}');
          await Future.delayed(_postRetryDelay);
          // 重试前重建 dio（确保新 socket）
          try {
            _dio.close(force: true);
          } catch (_) {}
          _dio = _buildDio();
          continue;
        }
        final code = e.response?.statusCode ?? 0;
        final respBody = e.response?.data?.toString() ?? '';
        print('[SpiderService] POST $url 失败: code=$code, type=${e.type}, message=${e.message}, body=${respBody.length > 500 ? respBody.substring(0, 500) : respBody}');
        return null;
      } catch (e) {
        print('[SpiderService] POST $url 未知错误: $e');
        return null;
      }
    }
    return null;
  }

  // ============================================================
  // Spider API - 所有方法都接受 key/type/apiBase 参数
  // ============================================================

  /// 获取 Spider 配置 - 对应 Swift getCatConfig
  /// 直接请求 Spider 服务器的 /config 端点（全局配置，不需要 key/type）
  Future<Map<String, dynamic>?> getCatConfig() async {
    if (!isSpiderReady) return null;

    final url = 'http://127.0.0.1:$_spiderPort/config';
    print('[SpiderService] getCatConfig: $url');

    try {
      final response = await _dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );

      final statusCode = response.statusCode ?? 0;
      final responseBody = response.data ?? '';

      if (statusCode >= 200 && statusCode <= 299) {
        try {
          final decoded = jsonDecode(responseBody);
          if (decoded is Map<String, dynamic>) {
            return decoded;
          }
          print('[SpiderService] getCatConfig 响应不是JSON对象: body类型=${decoded.runtimeType}');
          return null;
        } catch (e) {
          print('[SpiderService] getCatConfig JSON解析失败: 错误=$e, body=${responseBody.length > 500 ? responseBody.substring(0, 500) : responseBody}');
          return null;
        }
      } else {
        print('[SpiderService] getCatConfig HTTP错误 $statusCode: body=${responseBody.length > 500 ? responseBody.substring(0, 500) : responseBody}');
        return null;
      }
    } on DioException catch (e) {
      print('[SpiderService] getCatConfig 失败: ${e.type}, ${e.message}');
      return null;
    }
  }

  /// 初始化 Spider - 对应 Swift initSpider
  Future<Map<String, dynamic>?> initSpider(String key, int type, String apiBase) async {
    if (!isSpiderReady) return null;

    final url = _buildSpiderUrl(key, type, apiBase, 'init');
    print('[SpiderService] initSpider: $url');

    return _postJSON(url, <String, dynamic>{});
  }

  /// 获取首页内容 - 对应 Swift getHomeContent
  Future<Map<String, dynamic>?> getHomeContent(String key, int type, String apiBase) async {
    if (!isSpiderReady) return null;

    final url = _buildSpiderUrl(key, type, apiBase, 'home');
    print('[SpiderService] getHomeContent: $url');

    return _postJSON(url, <String, dynamic>{});
  }

  /// 获取分类内容 - 对应 Swift getCategoryContent
  Future<Map<String, dynamic>?> getCategoryContent(
    String key, int type, String apiBase,
    String id, {
    int page = 1,
    Map<String, dynamic>? filters,
  }) async {
    if (!isSpiderReady) return null;

    final url = _buildSpiderUrl(key, type, apiBase, 'category');
    print('[SpiderService] getCategoryContent: $url, id=$id, page=$page');

    final body = <String, dynamic>{
      'id': id,
      'page': page,
      'filter': filters != null && filters.isNotEmpty,
      'filters': filters ?? {},
    };

    return _postJSON(url, body);
  }

  /// 获取详情 - 对应 Swift getDetail
  Future<Map<String, dynamic>?> getDetail(String key, int type, String apiBase, String id) async {
    if (!isSpiderReady) return null;

    final url = _buildSpiderUrl(key, type, apiBase, 'detail');
    print('[SpiderService] getDetail: $url, id=$id');

    return _postJSON(url, {'id': id});
  }

  /// 获取播放 URL - 对应 Swift getPlayUrl
  Future<Map<String, dynamic>?> getPlayUrl(
      String key, int type, String apiBase, String flag, String id) async {
    if (!isSpiderReady) return null;

    final url = _buildSpiderUrl(key, type, apiBase, 'play');
    print('[SpiderService] getPlayUrl: $url, flag=$flag, id=$id');

    return _postJSON(url, {'flag': flag, 'id': id});
  }

  /// 搜索 - 对应 Swift search
  Future<Map<String, dynamic>?> search(
      String key, int type, String apiBase, String keyword, {int page = 1}) async {
    if (!isSpiderReady) return null;

    final url = _buildSpiderUrl(key, type, apiBase, 'search');
    print('[SpiderService] search: $url, keyword=$keyword, page=$page');

    return _postJSON(url, {'wd': keyword, 'page': page});
  }

  // ============================================================
  // searchWithSpider - 对应 Swift searchWithSpider
  // 原子操作：先 init 再 search，不受并发影响
  // ============================================================

  /// 使用指定 Spider 搜索 - 对应 Swift searchWithSpider
  /// 原子操作：先 init 再 search，不受并发影响
  Future<Map<String, dynamic>?> searchWithSpider({
    required String spiderKey,
    required int spiderType,
    required String apiBase,
    required String keyword,
    int page = 1,
  }) async {
    if (!isSpiderReady) return null;

    // 对应 Swift: 先 init（忽略错误），再 search
    try {
      await initSpider(spiderKey, spiderType, apiBase);
    } catch (_) {}

    return search(spiderKey, spiderType, apiBase, keyword, page: page);
  }

  // ============================================================
  // 兼容旧接口 - 保留 setCurrentSpider 等方法
  // 用于非并发场景（如首页加载、详情页）
  // ============================================================

  String? _currentKey;
  int? _currentType;
  String? _currentApiBase;

  /// 设置当前 Spider 信息 - 对应 Swift setCurrentSpider
  /// 仅用于非并发场景
  void setCurrentSpider(String key, int type, String? apiBase,
      {String? ext, String? jar}) {
    _currentKey = key;
    _currentType = type;
    _currentApiBase = apiBase;
    print('[SpiderService] setCurrentSpider: key=$key, type=$type, apiBase=$apiBase');
  }

  /// 获取当前 Spider 的 key/type/apiBase
  /// 用于非并发场景（如详情页获取播放 URL）
  (String, int, String) getCurrentSpiderInfo() {
    return (_currentKey!, _currentType!, _currentApiBase ?? '');
  }

  /// 使当前 Spider 会话失效 - 对应 Swift invalidateSession
  /// 关键：必须同时关闭并重建 dio，否则 iOS 后台/锁屏后切回前台时
  /// dio 复用的 socket 已被系统断开，所有请求会静默失败
  void invalidateSession() {
    _currentKey = null;
    _currentType = null;
    _currentApiBase = null;
    try {
      _dio.close(force: true);
    } catch (_) {}
    _dio = _buildDio();
  }
}
