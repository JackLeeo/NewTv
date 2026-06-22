import 'package:dio/dio.dart';
import '../common/constants.dart';

/// 网络层错误定义
enum NetworkError {
  invalidURL,
  invalidResponse,
  httpError,
  decodingError,
  networkUnavailable;

  String get description {
    switch (this) {
      case NetworkError.invalidURL:
        return '无效的URL';
      case NetworkError.invalidResponse:
        return '无效的响应';
      case NetworkError.httpError:
        return 'HTTP错误';
      case NetworkError.decodingError:
        return '解码错误';
      case NetworkError.networkUnavailable:
        return '网络不可用';
    }
  }
}

/// HTTP 客户端 - 对应 Swift NetworkManager
/// 使用 dio 实现，支持自动重试和编码检测
class NetworkManager {
  static final NetworkManager _instance = NetworkManager._internal();
  static NetworkManager get instance => _instance;

  static const int defaultMaxRetries = 2;
  static const double _retryBaseDelay = 0.5;
  static const double _retryMaxDelay = 8.0;

  /// 可重试的 HTTP 状态码
  static const _retryableStatusCodes = {408, 429, 500, 502, 503, 504};

  late Dio _dio;

  NetworkManager._internal() {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'User-Agent': AppConstants.defaultUserAgent,
      },
    ));
  }

  /// 重置 dio 实例（对应 Swift invalidateSession）
  void invalidateSession() {
    _dio.close(force: true);
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'User-Agent': AppConstants.defaultUserAgent,
      },
    ));
  }

  /// GET 请求获取字符串，支持自动重试
  Future<String> getString(
    String urlString, {
    Map<String, String>? headers,
    int maxRetries = defaultMaxRetries,
  }) async {
    final trimmedUrl = urlString.trim();
    final parsedUrl = Uri.tryParse(trimmedUrl);
    if (trimmedUrl.isEmpty || parsedUrl == null || !parsedUrl.hasScheme) {
      throw Exception('无效的URL: $urlString');
    }

    final totalAttempts = maxRetries + 1;
    Object? lastError;

    for (var attempt = 0; attempt < totalAttempts; attempt++) {
      try {
        final options = Options(
          method: 'GET',
          headers: headers,
          responseType: ResponseType.plain,
        );

        final response = await _dio.get<String>(
          trimmedUrl,
          options: options,
        );

        if (response.statusCode == null ||
            response.statusCode! < 200 ||
            response.statusCode! > 299) {
          final statusCode = response.statusCode ?? 0;

          if (_isRetryableHTTPStatus(statusCode) &&
              attempt < totalAttempts - 1) {
            lastError = Exception('HTTP错误: $statusCode');
            await _retryDelay(attempt);
            continue;
          }
          throw Exception('HTTP错误: $statusCode');
        }

        return response.data ?? '';
      } on DioException catch (e) {
        lastError = e;
        if (_isRetryableDioError(e) && attempt < totalAttempts - 1) {
          await _retryDelay(attempt);
          continue;
        }
        rethrow;
      }
    }

    throw lastError ?? Exception('请求失败');
  }

  /// GET 请求获取原始 Data
  Future<List<int>> getData(
    String urlString, {
    int maxRetries = defaultMaxRetries,
  }) async {
    final trimmedUrl = urlString.trim();

    final totalAttempts = maxRetries + 1;
    Object? lastError;

    for (var attempt = 0; attempt < totalAttempts; attempt++) {
      try {
        final response = await _dio.get<List<int>>(
          trimmedUrl,
          options: Options(responseType: ResponseType.bytes),
        );

        if (response.statusCode == null ||
            response.statusCode! < 200 ||
            response.statusCode! > 299) {
          final statusCode = response.statusCode ?? 0;

          if (_isRetryableHTTPStatus(statusCode) &&
              attempt < totalAttempts - 1) {
            lastError = Exception('HTTP错误: $statusCode');
            await _retryDelay(attempt);
            continue;
          }
          throw Exception('HTTP错误: $statusCode');
        }

        return response.data ?? [];
      } on DioException catch (e) {
        lastError = e;
        if (_isRetryableDioError(e) && attempt < totalAttempts - 1) {
          await _retryDelay(attempt);
          continue;
        }
        rethrow;
      }
    }

    throw lastError ?? Exception('请求失败');
  }

  /// 指数退避延迟 + 随机抖动
  Future<void> _retryDelay(int attempt) async {
    final base = _retryBaseDelay * (1 << attempt); // 2^attempt
    final jitter = DateTime.now().millisecond % 500 / 1000.0;
    final delay = (base + jitter).clamp(0.0, _retryMaxDelay);
    await Future.delayed(Duration(milliseconds: (delay * 1000).round()));
  }

  /// 判断 HTTP 状态码是否值得重试
  bool _isRetryableHTTPStatus(int statusCode) {
    return _retryableStatusCodes.contains(statusCode);
  }

  /// 判断 Dio 错误是否为可重试的瞬态网络错误
  bool _isRetryableDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.badResponse:
        final statusCode = e.response?.statusCode ?? 0;
        return _isRetryableHTTPStatus(statusCode);
      default:
        return false;
    }
  }
}
