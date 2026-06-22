import 'dart:io';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/player_engine.dart';
import '../../services/api_config.dart';
import '../../services/app_state.dart';
import '../../services/nodejs_manager.dart';
import '../../common/constants.dart';

enum PendingMultiRepoTarget { vod, live }

class PendingMultiRepoSelection {
  final String id;
  final PendingMultiRepoTarget target;
  final String sourceUrl;
  final List<MultiRepoOption> options;

  PendingMultiRepoSelection({
    required this.id,
    required this.target,
    required this.sourceUrl,
    required this.options,
  });
}

class SettingsController extends GetxController {
  final vodApiUrl = ''.obs;
  final liveApiUrl = ''.obs;
  final isLoadingConfig = false.obs;
  final configError = Rx<String?>(null);
  final configSuccess = false.obs;
  final pendingMultiRepoSelection = Rx<PendingMultiRepoSelection?>(null);
  final apiHistory = <String>[].obs;
  final vodPlayerEngine = PlayerEngine.mpv.obs;
  final livePlayerEngine = PlayerEngine.mpv.obs;
  final decodeMode = VideoDecodeMode.auto.obs;
  final vlcBufferMode = VLCBufferMode.balanced.obs;
  final playTimeStep = 10.obs;
  final cacheSizeString = '0 KB'.obs;

  bool _nodeJSStarted = false;

  final playTimeStepOptions = [5, 10, 15, 30, 60];
  List<PlayerEngine> get playerEngineOptions => PlayerEngine.availableEngines;
  List<VideoDecodeMode> get decodeModeOptions => VideoDecodeMode.values;
  List<VLCBufferMode> get vlcBufferModeOptions => VLCBufferMode.values;

  @override
  void onInit() {
    super.onInit();
    _initSettings();
  }

  Future<void> _initSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedVod = prefs.getString(AppConstants.apiUrl) ?? '';
    vodApiUrl.value = savedVod;
    final savedLive = prefs.getString(AppConstants.liveApiUrl);
    liveApiUrl.value = savedLive ?? savedVod;

    await _loadApiHistory();

    // 兼容老版本单一播放器字段到新字段
    final hasLegacyPlayer = prefs.containsKey(AppConstants.playType);
    final legacyPlayerRaw = prefs.getInt(AppConstants.playType) ?? 0;
    final defaultRaw = PlayerEngine.mpv.value;

    if (!prefs.containsKey(AppConstants.playTypeVod)) {
      await prefs.setInt(
        AppConstants.playTypeVod,
        hasLegacyPlayer ? legacyPlayerRaw : defaultRaw,
      );
    }
    if (!prefs.containsKey(AppConstants.playTypeLive)) {
      await prefs.setInt(
        AppConstants.playTypeLive,
        hasLegacyPlayer ? legacyPlayerRaw : defaultRaw,
      );
    }

    vodPlayerEngine.value = PlayerEngine.fromStoredValue(
      prefs.getInt(AppConstants.playTypeVod) ?? 0,
    );
    livePlayerEngine.value = PlayerEngine.fromStoredValue(
      prefs.getInt(AppConstants.playTypeLive) ?? 0,
    );
    decodeMode.value = VideoDecodeMode.fromStoredValue(
      prefs.getInt('play_decode_mode') ?? 0,
    );
    vlcBufferMode.value = VLCBufferMode.fromStoredValue(
      prefs.getInt('play_vlc_buffer_mode') ?? 0,
    );

    final savedStep = prefs.getInt('play_time_step') ?? 0;
    playTimeStep.value = savedStep > 0 ? savedStep : 10;

    refreshCacheSize();
  }

  Future<void> loadConfig() async {
    final trimmedVod = vodApiUrl.value.trim();
    final trimmedLive = liveApiUrl.value.trim();

    if (trimmedVod.isEmpty) {
      configError.value = '请输入点播接口地址';
      return;
    }

    isLoadingConfig.value = true;
    configError.value = null;
    configSuccess.value = false;
    pendingMultiRepoSelection.value = null;

    try {
      final resolvedLive = trimmedLive.isEmpty ? trimmedVod : trimmedLive;

      // 若探测到多仓库入口，先中断加载并弹出候选
      final pending = await _detectPendingMultiRepoSelection(
        vodUrl: trimmedVod,
        liveUrl: resolvedLive,
      );
      if (pending != null) {
        pendingMultiRepoSelection.value = pending;
        isLoadingConfig.value = false;
        return;
      }

      await ApiConfig.instance.loadConfigs(
        vodApiUrl: trimmedVod,
        liveApiUrl: resolvedLive,
      );

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConstants.apiUrl, trimmedVod);
      await prefs.setString(AppConstants.liveApiUrl, trimmedLive);
      vodApiUrl.value = trimmedVod;
      liveApiUrl.value = trimmedLive;
      await addToApiHistory(trimmedVod);
      await addToApiHistory(resolvedLive);
      configSuccess.value = true;

      // 对应 Swift: ensureNodeJSAndLoadSource()
      // 配置加载成功后启动 Node.js 并获取 Spider 配置
      try {
        final appState = Get.find<AppState>();
        await appState.ensureNodeJSAndLoadSource();
        appState.applyLoadedConfigState();
      } catch (_) {}
    } catch (e) {
      configError.value = e.toString();
    }

    isLoadingConfig.value = false;
  }

  Future<void> selectPendingMultiRepoOption(
      MultiRepoOption option) async {
    final pending = pendingMultiRepoSelection.value;
    if (pending == null) return;

    final normalizedSource =
        ApiConfig.normalizeConfigUrl(pending.sourceUrl);

    switch (pending.target) {
      case PendingMultiRepoTarget.vod:
        final normalizedLive =
            ApiConfig.normalizeConfigUrl(liveApiUrl.value);
        final shouldSyncLive =
            liveApiUrl.value.trim().isNotEmpty &&
                normalizedLive == normalizedSource;
        vodApiUrl.value = option.url;
        if (shouldSyncLive) {
          liveApiUrl.value = option.url;
        }
        break;
      case PendingMultiRepoTarget.live:
        liveApiUrl.value = option.url;
        break;
    }

    pendingMultiRepoSelection.value = null;
    await loadConfig();
  }

  void cancelPendingMultiRepoSelection() {
    pendingMultiRepoSelection.value = null;
    isLoadingConfig.value = false;
  }

  Future<PendingMultiRepoSelection?> _detectPendingMultiRepoSelection({
    required String vodUrl,
    required String liveUrl,
  }) async {
    final vodOptions =
        await ApiConfig.instance.fetchMultiRepoOptions(vodUrl);
    if (vodOptions != null) {
      if (vodOptions.isEmpty) {
        throw Exception('点播多仓库配置中没有可用地址');
      }
      return PendingMultiRepoSelection(
        id: '${DateTime.now().microsecondsSinceEpoch}',
        target: PendingMultiRepoTarget.vod,
        sourceUrl: vodUrl,
        options: vodOptions,
      );
    }

    final normalizedVod = ApiConfig.normalizeConfigUrl(vodUrl);
    final normalizedLive = ApiConfig.normalizeConfigUrl(liveUrl);
    if (normalizedLive == normalizedVod) return null;

    final liveOptions =
        await ApiConfig.instance.fetchMultiRepoOptions(liveUrl);
    if (liveOptions != null) {
      if (liveOptions.isEmpty) {
        throw Exception('直播多仓库配置中没有可用地址');
      }
      return PendingMultiRepoSelection(
        id: '${DateTime.now().microsecondsSinceEpoch}',
        target: PendingMultiRepoTarget.live,
        sourceUrl: liveUrl,
        options: liveOptions,
      );
    }

    return null;
  }

  Future<void> _loadApiHistory() async {
    final prefs = await SharedPreferences.getInstance();
    apiHistory.value = prefs.getStringList('api_history') ?? [];
  }

  Future<void> addToApiHistory(String url) async {
    apiHistory.remove(url);
    apiHistory.insert(0, url);
    if (apiHistory.length > 10) {
      apiHistory.removeRange(10, apiHistory.length);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('api_history', apiHistory.toList());
  }

  Future<void> removeApiHistory(String url) async {
    apiHistory.remove(url);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('api_history', apiHistory.toList());
  }

  /// 实际清除 Flutter 端所有缓存（图片 / HTTP 磁盘 / temp / app cache 目录）
  ///
  /// 涉及到的缓存：
  /// - `PaintingBinding.instance.imageCache` —— Flutter 内存图片缓存
  /// - `DefaultCacheManager` —— cached_network_image_ce 的磁盘缓存
  ///   （HLS / m3u8 切片、详情页海报、Home 列表缩略图都走它）
  /// - `getTemporaryDirectory()` —— Flutter / dio / webview 的临时文件
  /// - `getApplicationCacheDirectory()` —— 应用自定义缓存
  ///
  /// **不清** `<Documents>/` 下的 Node.js 源码（user 自己的 source URL 内容），
  /// 那个走 [NodeJSManager.deleteSource]，跟"清除缓存"是不同语义。
  Future<void> clearCache() async {
    // 1) Flutter 内存图片缓存
    try {
      final imageCache = PaintingBinding.instance.imageCache;
      imageCache.clear();
      imageCache.clearLiveImages();
    } catch (e) {
      debugPrint('=== clearCache: imageCache.clear failed: $e ===');
    }

    // 2) cached_network_image_ce 磁盘缓存
    try {
      await DefaultCacheManager().emptyCache();
      debugPrint('=== clearCache: DefaultCacheManager.emptyCache OK ===');
    } catch (e) {
      debugPrint('=== clearCache: DefaultCacheManager.emptyCache failed: $e ===');
    }

    // 3) getTemporaryDirectory()
    try {
      final tmpDir = await getTemporaryDirectory();
      await _deleteDirContents(tmpDir);
    } catch (e) {
      debugPrint('=== clearCache: tmp dir clear failed: $e ===');
    }

    // 4) getApplicationCacheDirectory()
    try {
      final appCacheDir = await getApplicationCacheDirectory();
      await _deleteDirContents(appCacheDir);
    } catch (e) {
      debugPrint('=== clearCache: app cache dir clear failed: $e ===');
    }

    // 5) 给用户反馈 + 刷新显示
    Get.snackbar(
      '清除缓存',
      '已清空图片 / 视频切片 / 临时文件',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
    await refreshCacheSize();
  }

  /// 重置配置：清除已保存的源 URL + 历史记录 + 下载的源缓存
  /// 下次启动 App 会回到 setupView（输入源 URL 的初始页面）
  /// 不会清播放器设置 / 主题 / 字体大小等本地化设置
  Future<bool> resetConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppConstants.apiUrl);
    await prefs.remove(AppConstants.liveApiUrl);
    await prefs.remove(AppConstants.homeApi);
    await prefs.remove('api_history');

    // 清内存中的状态
    vodApiUrl.value = '';
    liveApiUrl.value = '';
    apiHistory.clear();

    // 删下载的源缓存（<Documents>/nodejs/source/）
    // 下次进 setupView 输入新 URL 时会重新下载
    try {
      await NodeJSManager.instance.deleteSource();
    } catch (_) {}

    return true;
  }

  Future<void> setPlayTimeStep(int step) async {
    if (step <= 0) return;
    playTimeStep.value = step;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('play_time_step', step);
  }

  Future<void> setVodPlayerEngine(PlayerEngine engine) async {
    if (!playerEngineOptions.contains(engine)) return;
    vodPlayerEngine.value = engine;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(AppConstants.playTypeVod, engine.value);
  }

  Future<void> setLivePlayerEngine(PlayerEngine engine) async {
    if (!playerEngineOptions.contains(engine)) return;
    livePlayerEngine.value = engine;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(AppConstants.playTypeLive, engine.value);
  }

  Future<void> setDecodeMode(VideoDecodeMode mode) async {
    if (!decodeModeOptions.contains(mode)) return;
    decodeMode.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('play_decode_mode', mode.value);
  }

  Future<void> setVLCBufferMode(VLCBufferMode mode) async {
    if (!vlcBufferModeOptions.contains(mode)) return;
    vlcBufferMode.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('play_vlc_buffer_mode', mode.value);
  }

  /// 重新计算并刷新"缓存大小"显示
  ///
  /// 实际意义 = imageCache 内存估算 + temp 目录 + app cache 目录
  /// （cached_network_image_ce 的磁盘缓存在 app cache 下面的
  /// `libCachedImageData/` 子目录，递归算 app cache 时已包含）
  Future<void> refreshCacheSize() async {
    int total = 0;

    // 1) Flutter 内存图片缓存
    try {
      final imageCache = PaintingBinding.instance.imageCache;
      total += imageCache.currentSizeBytes;
    } catch (_) {}

    // 2) getTemporaryDirectory() —— Flutter / dio / webview 临时文件
    try {
      final tmpDir = await getTemporaryDirectory();
      total += await _dirSize(tmpDir);
    } catch (e) {
      debugPrint('=== refreshCacheSize: tmp dir size failed: $e ===');
    }

    // 3) getApplicationCacheDirectory() —— 包含 cached_network_image 磁盘缓存
    try {
      final appCacheDir = await getApplicationCacheDirectory();
      total += await _dirSize(appCacheDir);
    } catch (e) {
      debugPrint('=== refreshCacheSize: app cache dir size failed: $e ===');
    }

    cacheSizeString.value = _formatSize(bytes: total);
  }

  /// 递归算目录字节数（不跟符号链接，防循环）
  Future<int> _dirSize(Directory dir) async {
    int total = 0;
    try {
      if (!await dir.exists()) return 0;
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('=== _dirSize: ${dir.path} failed: $e ===');
    }
    return total;
  }

  /// 删除目录所有内容（保留目录本身）
  Future<void> _deleteDirContents(Directory dir) async {
    try {
      if (!await dir.exists()) return;
      await for (final entity
          in dir.list(recursive: false, followLinks: false)) {
        try {
          if (entity is File) {
            await entity.delete();
          } else if (entity is Directory) {
            await entity.delete(recursive: true);
          }
        } catch (e) {
          debugPrint(
              '=== _deleteDirContents: ${entity.path} failed: $e ===');
        }
      }
    } catch (e) {
      debugPrint('=== _deleteDirContents: ${dir.path} failed: $e ===');
    }
  }

  static String _formatSize({required int bytes}) {
    final size = bytes < 0 ? 0 : bytes;
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) {
      return '${(size / 1024.0).toStringAsFixed(1)} KB';
    }
    if (size < 1024 * 1024 * 1024) {
      return '${(size / 1024.0 / 1024.0).toStringAsFixed(1)} MB';
    }
    return '${(size / 1024.0 / 1024.0 / 1024.0).toStringAsFixed(2)} GB';
  }
}
