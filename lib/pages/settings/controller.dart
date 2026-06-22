import 'package:get/get.dart';
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

  void clearCache() {
    // Flutter 端清除网络缓存和图片缓存
    // 目前仅刷新缓存大小显示
    refreshCacheSize();
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

  void refreshCacheSize() {
    // Flutter 端暂无精确的磁盘缓存统计，显示占位值
    cacheSizeString.value = _formatSize(bytes: 0);
  }

  static String _formatSize({required int bytes}) {
    final size = bytes < 0 ? 0 : bytes;
    if (size < 1024 * 1024) {
      return '${(size / 1024.0).toStringAsFixed(1)} KB';
    }
    return '${(size / 1024.0 / 1024.0).toStringAsFixed(1)} MB';
  }
}
