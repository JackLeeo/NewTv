import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:get/get.dart';
import 'api_config.dart';
import 'nodejs_manager.dart';
import 'spider_service.dart';
import 'network_manager.dart';
import '../models/source_bean.dart';

/// 加载阶段 - 对应 Swift LoadingPhase
enum LoadingPhase {
  idle,
  loadingConfig,
  startingNodeJS,
  downloadingSource,
  verifyingMD5,
  loadingSource,
  waitingSpiderPort,
  fetchingSpiderConfig,
  initializingSpider,
  reconnecting,
  completed,
  failed,
}

/// 加载阶段描述 - 对应 Swift LoadingPhase.displayText
extension LoadingPhaseDesc on LoadingPhase {
  String get description {
    switch (this) {
      case LoadingPhase.idle:
        return '';
      case LoadingPhase.loadingConfig:
        return '正在加载配置...';
      case LoadingPhase.startingNodeJS:
        return '正在启动 Node.js 运行时...';
      case LoadingPhase.downloadingSource:
        return '正在下载源文件...';
      case LoadingPhase.verifyingMD5:
        return '正在校验文件完整性...';
      case LoadingPhase.loadingSource:
        return '正在加载 Spider 源...';
      case LoadingPhase.waitingSpiderPort:
        return '等待 Spider 服务就绪...';
      case LoadingPhase.fetchingSpiderConfig:
        return '正在获取线路配置...';
      case LoadingPhase.initializingSpider:
        return '正在初始化 Spider...';
      case LoadingPhase.reconnecting:
        return '正在重连服务...';
      case LoadingPhase.completed:
        return '加载完成';
      case LoadingPhase.failed:
        return '加载失败';
    }
  }

  /// 是否正在加载 - 对应 Swift LoadingPhase.isLoading
  bool get isLoading =>
      this != LoadingPhase.idle &&
      this != LoadingPhase.completed &&
      this != LoadingPhase.failed;

  /// 是否失败 - 对应 Swift LoadingPhase.isFailed
  bool get isFailed => this == LoadingPhase.failed;
}

/// 应用状态控制器 - 对应 Swift AppState
/// 管理整个配置加载生命周期
class AppState extends GetxController {
  final loadingPhase = LoadingPhase.idle.obs;
  final isConfigLoaded = false.obs;
  final currentSourceKey = ''.obs;
  final configLoadError = Rx<String?>(null);
  final isRetryingConfig = false.obs;
  final pendingSearchKeyword = Rx<String?>(null);
  final showAboutOnLaunch = false.obs;

  String _lastVodUrl = '';
  String _lastLiveUrl = '';
  bool _nodeJSStarted = false;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  @override
  void onInit() {
    super.onInit();
    _setupNetworkRestoredAutoRetry();
  }

  @override
  void onClose() {
    _connectivitySubscription?.cancel();
    NodeJSManager.instance.stopNodeJS();
    super.onClose();
  }

  /// 加载阶段显示文本（合并错误信息）- 对应 Swift LoadingPhase.displayText
  /// Swift 中 failed 携带关联值，Dart 通过 configLoadError 补全
  String get phaseDisplayText {
    if (loadingPhase.value == LoadingPhase.failed &&
        configLoadError.value != null) {
      return '加载失败: ${configLoadError.value}';
    }
    return loadingPhase.value.description;
  }

  /// 是否正在加载
  bool get isLoading => loadingPhase.value.isLoading;

  /// 是否加载失败
  bool get isFailed => loadingPhase.value.isFailed;

  // ============================================================
  // 配置加载主流程 - 对应 Swift loadConfig
  // ============================================================

  /// 加载配置（仅点播 URL）- 对应 Swift loadConfig(url:)
  Future<void> loadConfig(String url) async {
    await loadConfigWithLive(vodUrl: url, liveUrl: null);
  }

  /// 加载配置（分别指定点播和直播 URL）- 对应 Swift loadConfig(vodUrl:liveUrl:)
  Future<void> loadConfigWithLive({
    required String vodUrl,
    String? liveUrl,
  }) async {
    final trimmedVod = vodUrl.trim();
    final trimmedLive = (liveUrl ?? '').trim();
    if (trimmedVod.isEmpty) return;
    final resolvedLive = trimmedLive.isEmpty ? trimmedVod : trimmedLive;

    _lastVodUrl = trimmedVod;
    _lastLiveUrl = resolvedLive;
    configLoadError.value = null;
    loadingPhase.value = LoadingPhase.loadingConfig;

    try {
      await ApiConfig.instance.loadConfigs(
        vodApiUrl: trimmedVod,
        liveApiUrl: resolvedLive,
      );
      await _ensureNodeJSAndLoadSource();
      loadingPhase.value = LoadingPhase.completed;
      applyLoadedConfigState();
    } catch (e) {
      configLoadError.value = e.toString();
      loadingPhase.value = LoadingPhase.failed;
    }
  }

  /// 应用已加载的配置状态 - 对应 Swift applyLoadedConfigState
  void applyLoadedConfigState() {
    isConfigLoaded.value = true;
    configLoadError.value = null;
    currentSourceKey.value =
        ApiConfig.instance.homeSourceBean.value?.key ?? '';
    showAboutOnLaunch.value = true;
  }

  // ============================================================
  // Spider 源加载 - 对应 Swift ensureNodeJSAndLoadSource
  // ============================================================

  /// 确保 Node.js 已启动并加载 Spider 源 - 对应 Swift ensureNodeJSAndLoadSource
  /// 公开方法，供 SettingsController 调用
  Future<void> ensureNodeJSAndLoadSource() async {
    await _ensureNodeJSAndLoadSource();
  }

  /// 确保 Node.js 已启动并加载 Spider 源 - 对应 Swift ensureNodeJSAndLoadSource
  Future<void> _ensureNodeJSAndLoadSource() async {
    final hasSpiderSource =
        ApiConfig.instance.sourceBeanList.any((s) => s.isSpiderSource);
    if (!hasSpiderSource) return;

    if (!_nodeJSStarted) {
      loadingPhase.value = LoadingPhase.startingNodeJS;
      final success = await NodeJSManager.instance.startNodeJS();
      if (success) {
        _nodeJSStarted = true;
        await _loadSpiderSource();
      } else {
        loadingPhase.value = LoadingPhase.failed;
        configLoadError.value = 'Node.js 启动失败';
        print('[AppState] Node.js 启动失败');
      }
    } else {
      await _loadSpiderSource();
    }
  }

  /// 加载 Spider 源 - 对应 Swift loadSpiderSource
  Future<void> _loadSpiderSource() async {
    final spiderSource = ApiConfig.instance.sourceBeanList
        .firstWhereOrNull((s) => s.isSpiderSource);
    if (spiderSource == null || spiderSource.api.isEmpty) return;

    loadingPhase.value = LoadingPhase.downloadingSource;
    final (loadSuccess, loadMessage) =
        await NodeJSManager.instance.loadSource(spiderSource.api);

    if (!loadSuccess) {
      loadingPhase.value = LoadingPhase.failed;
      configLoadError.value = 'Spider 源加载失败';
      print('[AppState] Spider 源加载失败: ${loadMessage ?? "未知错误"}');
      return;
    }
    print('[AppState] Spider 源加载成功');

    loadingPhase.value = LoadingPhase.waitingSpiderPort;
    final portReady = await NodeJSManager.instance.waitForSpiderPort();
    if (!portReady) {
      loadingPhase.value = LoadingPhase.failed;
      configLoadError.value = '等待 Spider 服务超时';
      print('[AppState] 等待 spiderPort 超时');
      return;
    }

    await _fetchSpiderConfig();
  }

  /// 获取 Spider 配置 - 对应 Swift fetchSpiderConfig
  Future<void> _fetchSpiderConfig() async {
    final spiderPort = NodeJSManager.instance.spiderPort;
    if (spiderPort <= 0) {
      loadingPhase.value = LoadingPhase.failed;
      configLoadError.value = 'Spider 端口为 0';
      print('[AppState] spiderPort 为 0，无法获取线路配置');
      return;
    }

    loadingPhase.value = LoadingPhase.fetchingSpiderConfig;

    // 对应 Swift: getCatConfig 不需要 setCurrentSpider
    // /config 是全局端点，不需要 key/type
    try {
      final config = await SpiderService.instance.getCatConfig();
      if (config == null) {
        loadingPhase.value = LoadingPhase.failed;
        configLoadError.value = '获取线路配置失败';
        return;
      }
      await ApiConfig.instance
          .updateSourceBeansFromSpiderConfig(config, '');

      // 对应 Swift: 用第一个源设置 currentSpider 并初始化
      final firstSource = ApiConfig.instance.sourceBeanList.firstOrNull;
      if (firstSource != null) {
        loadingPhase.value = LoadingPhase.initializingSpider;
        // 对应 Swift: apiBase = firstSource.api
        // Spider config 返回的 api 字段可能是空字符串或相对路径
        final apiBase = firstSource.api.startsWith('http') ? '' : firstSource.api;
        // 设置当前 Spider（用于详情页等非并发场景）
        SpiderService.instance.setCurrentSpider(
          firstSource.key,
          firstSource.type,
          apiBase,
          ext: firstSource.ext,
          jar: firstSource.jar,
        );
        // 对应 Swift try? await - 忽略初始化错误
        try {
          await SpiderService.instance.initSpider(
            firstSource.key, firstSource.type, apiBase);
        } catch (_) {}
      }
    } catch (e) {
      loadingPhase.value = LoadingPhase.failed;
      configLoadError.value = '获取线路配置失败';
      print('[AppState] 获取 Spider 配置失败: $e');
    }
  }

  // ============================================================
  // 网络恢复自动重试 - 对应 Swift setupNetworkRestoredAutoRetry
  // ============================================================

  void _setupNetworkRestoredAutoRetry() {
    _connectivitySubscription = Connectivity()
        .onConnectivityChanged
        .listen((List<ConnectivityResult> results) {
      final isConnected = results.any((r) => r != ConnectivityResult.none);
      if (isConnected &&
          !isConfigLoaded.value &&
          _lastVodUrl.isNotEmpty) {
        isRetryingConfig.value = true;
        loadConfigWithLive(vodUrl: _lastVodUrl, liveUrl: _lastLiveUrl)
            .then((_) {
          isRetryingConfig.value = false;
        });
      }
    });
  }

  // ============================================================
  // 应用恢复前台处理 - 对应 Swift handleSceneActive
  // ============================================================

  /// 应用恢复前台时检查服务状态 - 对应 Swift handleSceneActive
  Future<void> handleSceneActive() async {
    if (!isConfigLoaded.value) return;
    final hasSpiderSource =
        ApiConfig.instance.sourceBeanList.any((s) => s.isSpiderSource);
    if (!hasSpiderSource) return;

    final spiderPort = NodeJSManager.instance.spiderPort;
    final nodeIsRunning = NodeJSManager.instance.isRunning;

    if (spiderPort > 0 && nodeIsRunning) {
      if (await NodeJSManager.instance.checkLocalPort(spiderPort)) return;
    }

    loadingPhase.value = LoadingPhase.reconnecting;
    SpiderService.instance.invalidateSession();
    NetworkManager.instance.invalidateSession();

    if (!nodeIsRunning) {
      _nodeJSStarted = false;
      await _ensureNodeJSAndLoadSource();

      if (_nodeJSStarted) {
        loadingPhase.value = LoadingPhase.completed;
      } else {
        loadingPhase.value = LoadingPhase.failed;
        configLoadError.value = '服务重连失败，请下拉刷新重试';
      }
    } else {
      final recovered = await _recoverSpiderService();
      if (recovered) {
        loadingPhase.value = LoadingPhase.completed;
      } else {
        loadingPhase.value = LoadingPhase.failed;
        configLoadError.value = '服务已断开，请关闭应用后重新打开';
      }
    }
  }

  /// 恢复 Spider 服务 - 对应 Swift recoverSpiderService
  Future<bool> _recoverSpiderService() async {
    await Future.delayed(const Duration(seconds: 2));

    for (var attempt = 0; attempt < 4; attempt++) {
      final spiderPort = NodeJSManager.instance.spiderPort;
      if (spiderPort > 0) {
        if (await NodeJSManager.instance.checkLocalPort(spiderPort)) {
          _nodeJSStarted = true;
          return true;
        }
      }

      final managementPort = NodeJSManager.instance.managementPort;
      if (managementPort > 0) {
        if (await NodeJSManager.instance.checkLocalPort(managementPort)) {
          final reloaded = await NodeJSManager.instance
              .reloadSourceViaManagementPort(managementPort);
          if (reloaded) {
            _nodeJSStarted = true;
            return true;
          }
        }
      }

      if (attempt < 3) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    return false;
  }

  // ============================================================
  // 全屏控制（桌面端）- 对应 Swift enterPlayerFullScreen / exitPlayerFullScreen
  // ============================================================

  bool _isPlayerFullScreen = false;

  bool get isPlayerFullScreen => _isPlayerFullScreen;

  /// 进入播放器全屏 - 对应 Swift enterPlayerFullScreen
  void enterPlayerFullScreen() {
    _isPlayerFullScreen = true;
  }

  /// 退出播放器全屏 - 对应 Swift exitPlayerFullScreen
  void exitPlayerFullScreen() {
    _isPlayerFullScreen = false;
  }

  // ============================================================
  // 辅助方法
  // ============================================================

  /// 重置状态
  void reset() {
    loadingPhase.value = LoadingPhase.idle;
    configLoadError.value = null;
  }
}
