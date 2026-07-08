import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:get/get.dart';
import 'api_config.dart';
import 'app_log.dart';
import 'nodejs_manager.dart';
import 'spider_service.dart';
import 'network_manager.dart';
import '../models/source_bean.dart';

/// 加载阶段 - 对应 Swift LoadingPhase
enum LoadingPhase {
  idle,
  loadingConfig,
  startingNodeJS,
  downloadingNodeJS,
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
      case LoadingPhase.downloadingNodeJS:
        return '首次启动需要下载 Node.js 运行时...';
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

  /// 重入 guard - 避免 lifecycle 抖动导致 handleSceneActive 嵌套跑
  /// 第二次及以后的调用直接跳过, 不浪费 CPU 也不互相覆盖 loadingPhase
  bool _isHandleSceneActiveRunning = false;

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
      // 0) 如果 node.exe 缺失，先下载（弹进度 dialog）
      try {
        if (!await NodeJSManager.instance.isNodeRuntimeInstalled()) {
          print('[AppState] node.exe 缺失，准备下载...');
          AppLog.instance.log('node.exe 缺失, 准备下载');
          loadingPhase.value = LoadingPhase.downloadingNodeJS;
          final cfg = NodeJSManager.instance.nodeDownloadConfig ??
              await NodeJSManager.loadNodeDownloadConfigStatic();
          try {
            await NodeJSManager.instance.downloadAndExtractNodeRuntime(cfg);
          } catch (e) {
            loadingPhase.value = LoadingPhase.failed;
            configLoadError.value = 'Node.js 下载失败: $e';
            print('[AppState] Node.js 下载失败: $e');
            AppLog.instance.log('Node.js 下载失败: $e');
            return;
          }
        }
      } catch (e) {
        AppLog.instance.log('isNodeRuntimeInstalled 异常: $e');
      }

      AppLog.instance.log('phase=startingNodeJS');
      loadingPhase.value = LoadingPhase.startingNodeJS;
      try {
        AppLog.instance.log('调 startNodeJS');
        final success = await NodeJSManager.instance.startNodeJS();
        AppLog.instance.log('startNodeJS 返回: $success');
        if (success) {
          _nodeJSStarted = true;
          AppLog.instance.log('调 _loadSpiderSource');
          await _loadSpiderSource();
        } else {
          loadingPhase.value = LoadingPhase.failed;
          configLoadError.value = 'Node.js 启动失败';
          print('[AppState] Node.js 启动失败');
          AppLog.instance.log('Node.js 启动失败');
        }
      } catch (e, st) {
        AppLog.instance.log('startNodeJS 异常: $e\n$st');
        loadingPhase.value = LoadingPhase.failed;
        configLoadError.value = 'Node.js 启动异常: $e';
        print('[AppState] Node.js 启动异常: $e');
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
  ///
  /// **回退到 0199b73 行为**（用户测试 0199b73 能正常恢复锁屏切回）:
  /// 1. 立即重建 dio（恢复 iOS 后台断开的 socket）
  /// 2. 真实 HTTP 探测 verifySpiderService（2s 超时，验证 sourceLoaded=true）
  /// 3. 失败时主动 reloadSourceViaManagementPort 让 Node.js 重新 loadScript
  /// 4. 等新 spiderPort（reload 后源会重新 listen 端口）
  /// 5. 失败兜底走 _recoverSpiderService（4 次重试）
  ///
  /// **不**用 verifyManagementPort (0b59c5f 引入) - 用户反映
  /// verifyManagementPort=false 走 forceReset + 完整重启路径反而
  /// 导致不能恢复, 而 0199b73 走 reload 源 + 兜底 4 次重试能恢复.
  /// iOS 后台冻住 Node.js 进程时, Node.js 实际还能响应 (iOS 唤醒
  /// 时 process 解冻), _recoverSpiderService 4 次重试 (8s 窗口)
  /// 内能 reload 成功.
  ///
  /// **不**用 forceResetRunningState (0b59c5f 引入) - 即使 1c5ecf7
  /// 修了 forceReset 不调 _stopHttpServer, forceReset 整体路径在
  /// 用户环境上仍破坏恢复. 79177e1 行为是兜底, 不破坏 notify 链路.
  Future<void> handleSceneActive() async {
    if (!isConfigLoaded.value) return;
    final hasSpiderSource =
        ApiConfig.instance.sourceBeanList.any((s) => s.isSpiderSource);
    if (!hasSpiderSource) return;

    // **重入 guard**: 避免 lifecycle 抖动 (resumed→inactive→hidden→paused
    // 间隔 12ms/3ms/0ms) 导致 handleSceneActive 嵌套跑.
    // cid_1 卡在 reload 125.8 秒时, 第二次 handleSceneActive 进来 (cid_2)
    // 浪费 CPU 跑完整 4 次重试, 并可能覆盖 loadingPhase.
    if (_isHandleSceneActiveRunning) {
      AppLog.instance.entry(LogEntry(
        category: 'GUARD',
        action: 'handleSceneActive_skip',
        level: LogLevel.warn,
        message: 'handleSceneActive already running, skip duplicate call',
        fields: {'reason': 'already running'},
      ));
      return;
    }
    _isHandleSceneActiveRunning = true;

    try {
      await _handleSceneActiveImpl();
    } finally {
      _isHandleSceneActiveRunning = false;
    }
  }

  /// handleSceneActive 实际逻辑 - 重入 guard try/finally 包裹
  Future<void> _handleSceneActiveImpl() async {
    final startAt = DateTime.now();
    final hasSpiderSource =
        ApiConfig.instance.sourceBeanList.any((s) => s.isSpiderSource);
    final spiderPort = NodeJSManager.instance.spiderPort;
    final managementPort = NodeJSManager.instance.managementPort;
    final nodeIsRunning = NodeJSManager.instance.isRunning;

    final cid = AppLog.instance.sceneStart(
      'handleSceneActive',
      fields: {
        'spiderPort': spiderPort,
        'managementPort': managementPort,
        'nodeIsRunning': nodeIsRunning,
        'hasSpiderSource': hasSpiderSource,
        'isConfigLoaded': isConfigLoaded.value,
        'loadingPhase': loadingPhase.value.name,
      },
    );

    // **第零关**: 如果 Node.js 已死 (isRunning=false), 先重启
    // iOS SIGKILL 场景: Swift 端 onNodeExit 因 node_start 阻塞不返回没跑,
    // Swift 主动 ping /check 失败时发 onNodeExit 给 Dart, Dart onNodeExit
    // 收到时清 isRunning/旧端口. handleSceneActive 看到 isRunning=false
    // 调 startNodeJS 重启. 注意: startNodeJS 调 Swift 启动新 Node.js, 新
    // Node.js 启动后会通过 onCatPawOpenPort 通知新端口给 Dart (Dart HTTP
    // server 一直跑没停, 通知链没断).
    if (!nodeIsRunning) {
      AppLog.instance.sceneStep(cid, 'restart_needed',
          fields: {
            'reason': 'isRunning=false, Node.js 已死 (iOS SIGKILL 或异常退出)',
            'oldSpiderPort': spiderPort,
            'oldMgmtPort': managementPort,
          });
      final restartStart = DateTime.now();
      final restartOk = await NodeJSManager.instance.startNodeJS();
      AppLog.instance.sceneStep(
        cid,
        restartOk ? 'restart_ok' : 'restart_fail',
        elapsedMs: DateTime.now().difference(restartStart).inMilliseconds,
        level: restartOk ? LogLevel.info : LogLevel.error,
        fields: {'ok': restartOk},
      );
      if (!restartOk) {
        loadingPhase.value = LoadingPhase.failed;
        configLoadError.value = 'Node.js 重启失败, 请关闭应用后重新打开';
        AppLog.instance.sceneEnd(
          cid,
          'restart_fail',
          elapsedMs: DateTime.now().difference(startAt).inMilliseconds,
          ok: false,
          fields: {'path': 'restart'},
        );
        return;
      }
      // 启动成功, 重新读端口 (新 Node.js 刚 listen, 应该已经通过
      // onCatPawOpenPort 通知过). 短暂 wait 让 Dart 同步最新状态.
      await Future.delayed(const Duration(milliseconds: 500));
    }

    // **第一步**: 立即重建 dio：恢复 iOS 后台断开的 socket
    AppLog.instance.sceneStep(cid, 'invalidate_dio',
        fields: {'reason': 'iOS 后台断开 socket 恢复'});
    SpiderService.instance.invalidateSession();
    NetworkManager.instance.invalidateSession();

    // **第二关**: 真实 HTTP 探测 Spider 服务
    if (spiderPort > 0) {
      final verifyStart = DateTime.now();
      AppLog.instance.sceneStep(cid, 'verify_start',
          fields: {'spiderPort': spiderPort});
      try {
        final ok =
            await NodeJSManager.instance.verifySpiderService(spiderPort);
        AppLog.instance.sceneStep(
          cid,
          ok ? 'verify_ok' : 'verify_fail',
          elapsedMs: DateTime.now().difference(verifyStart).inMilliseconds,
          fields: {'spiderPort': spiderPort, 'ok': ok},
        );
        if (ok) {
          AppLog.instance.sceneEnd(
            cid,
            'verify_ok',
            elapsedMs: DateTime.now().difference(startAt).inMilliseconds,
            ok: true,
            fields: {'path': 'verify'},
          );
          return;
        }
      } catch (e) {
        AppLog.instance.sceneStep(
          cid,
          'verify_exception',
          elapsedMs: DateTime.now().difference(verifyStart).inMilliseconds,
          level: LogLevel.error,
          fields: {'spiderPort': spiderPort},
          error: e.toString(),
        );
      }
    } else {
      AppLog.instance.sceneStep(cid, 'verify_skip',
          fields: {'reason': 'spiderPort=0'});
    }

    loadingPhase.value = LoadingPhase.reconnecting;
    AppLog.instance.sceneStep(cid, 'phase_reconnecting');

    // **第三关**: 尝试 reload 源 (不判定 Node.js 死活)
    if (managementPort > 0) {
      final oldSpiderPort = spiderPort;
      final reloadStart = DateTime.now();
      AppLog.instance.sceneStep(cid, 'reload_start',
          fields: {'managementPort': managementPort});
      final reloaded = await NodeJSManager.instance
          .reloadSourceViaManagementPort(managementPort);
      AppLog.instance.sceneStep(
        cid,
        reloaded ? 'reload_ok' : 'reload_fail',
        elapsedMs: DateTime.now().difference(reloadStart).inMilliseconds,
        fields: {'managementPort': managementPort, 'ok': reloaded},
      );
      if (reloaded) {
        // 等新 spiderPort, 10s
        var newPortSeen = false;
        var portSeenAt = 0;
        for (var i = 0; i < 20; i++) {
          final newPort = NodeJSManager.instance.spiderPort;
          if (newPort > 0 && newPort != oldSpiderPort) {
            newPortSeen = true;
            portSeenAt = i * 500;
            break;
          }
          await Future.delayed(const Duration(milliseconds: 500));
        }
        if (newPortSeen) {
          AppLog.instance.sceneStep(cid, 'new_spider_port',
              elapsedMs: portSeenAt,
              fields: {
                'oldSpiderPort': oldSpiderPort,
                'newSpiderPort': NodeJSManager.instance.spiderPort,
              });
          await Future.delayed(const Duration(seconds: 1));
          _nodeJSStarted = true;
          loadingPhase.value = LoadingPhase.completed;
          AppLog.instance.sceneEnd(
            cid,
            'reload_ok',
            elapsedMs: DateTime.now().difference(startAt).inMilliseconds,
            ok: true,
            fields: {'path': 'reload'},
          );
          return;
        }
        AppLog.instance.sceneStep(cid, 'reload_no_new_port',
            level: LogLevel.warn,
            fields: {'oldSpiderPort': oldSpiderPort, 'waitedMs': 10000});
      }
    } else {
      AppLog.instance.sceneStep(cid, 'reload_skip',
          fields: {'reason': 'managementPort=0'});
    }

    // **第四关**: 兜底 _recoverSpiderService
    AppLog.instance.sceneStep(cid, 'recover_start',
        fields: {'reason': 'verify+reload 都失败, 走兜底 4 次重试'});
    final recoverStart = DateTime.now();
    final recovered = await _recoverSpiderService(cid);
    AppLog.instance.sceneStep(
      cid,
      recovered ? 'recover_ok' : 'recover_fail',
      elapsedMs: DateTime.now().difference(recoverStart).inMilliseconds,
      level: recovered ? LogLevel.info : LogLevel.error,
      fields: {'ok': recovered},
    );

    if (recovered) {
      loadingPhase.value = LoadingPhase.completed;
    } else {
      loadingPhase.value = LoadingPhase.failed;
      configLoadError.value = '服务已断开，请关闭应用后重新打开';
    }
    AppLog.instance.sceneEnd(
      cid,
      recovered ? 'recover_ok' : 'recover_fail',
      elapsedMs: DateTime.now().difference(startAt).inMilliseconds,
      ok: recovered,
      fields: {
        'path': 'recover',
        'finalSpiderPort': NodeJSManager.instance.spiderPort,
        'finalMgmtPort': NodeJSManager.instance.managementPort,
        'finalNodeIsRunning': NodeJSManager.instance.isRunning,
      },
    );
  }

  /// 恢复 Spider 服务 - 对应 Swift recoverSpiderService
  ///
  /// [cid] handleSceneActive 的 correlation id, 串联所有日志
  Future<bool> _recoverSpiderService(String cid) async {
    AppLog.instance.sceneStep(cid, 'recover_wait_2s');
    await Future.delayed(const Duration(seconds: 2));

    for (var attempt = 0; attempt < 4; attempt++) {
      final attemptNo = attempt + 1;
      AppLog.instance.sceneStep(cid, 'recover_attempt',
          fields: {'attempt': attemptNo, 'maxAttempts': 4});

      final spiderPort = NodeJSManager.instance.spiderPort;
      AppLog.instance.sceneStep(cid, 'recover_check_spider',
          fields: {'attempt': attemptNo, 'spiderPort': spiderPort});
      if (spiderPort > 0) {
        final checkStart = DateTime.now();
        final portOk =
            await NodeJSManager.instance.checkLocalPort(spiderPort);
        AppLog.instance.sceneStep(
          cid,
          'recover_check_spider_result',
          elapsedMs: DateTime.now().difference(checkStart).inMilliseconds,
          fields: {'attempt': attemptNo, 'spiderPort': spiderPort, 'ok': portOk},
        );
        if (portOk) {
          AppLog.instance.sceneStep(cid, 'recover_spider_ok',
              fields: {'attempt': attemptNo, 'spiderPort': spiderPort});
          _nodeJSStarted = true;
          return true;
        }
      }

      final managementPort = NodeJSManager.instance.managementPort;
      AppLog.instance.sceneStep(cid, 'recover_check_mgmt',
          fields: {'attempt': attemptNo, 'managementPort': managementPort});
      if (managementPort > 0) {
        final checkStart = DateTime.now();
        final portOk =
            await NodeJSManager.instance.checkLocalPort(managementPort);
        AppLog.instance.sceneStep(
          cid,
          'recover_check_mgmt_result',
          elapsedMs: DateTime.now().difference(checkStart).inMilliseconds,
          fields: {
            'attempt': attemptNo,
            'managementPort': managementPort,
            'ok': portOk
          },
        );
        if (portOk) {
          final reloadStart = DateTime.now();
          final reloaded = await NodeJSManager.instance
              .reloadSourceViaManagementPort(managementPort);
          AppLog.instance.sceneStep(
            cid,
            'recover_mgmt_reload',
            elapsedMs: DateTime.now().difference(reloadStart).inMilliseconds,
            fields: {
              'attempt': attemptNo,
              'managementPort': managementPort,
              'ok': reloaded
            },
          );
          if (reloaded) {
            _nodeJSStarted = true;
            return true;
          }
        } else {
          AppLog.instance.sceneStep(cid, 'recover_mgmt_fail',
              fields: {'attempt': attemptNo, 'managementPort': managementPort});
        }
      } else {
        AppLog.instance.sceneStep(cid, 'recover_mgmt_skip',
            fields: {'attempt': attemptNo, 'reason': 'managementPort=0'});
      }

      if (attempt < 3) {
        AppLog.instance.sceneStep(cid, 'recover_wait_2s',
            fields: {'attempt': attemptNo, 'nextAttemptIn': '2s'});
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    AppLog.instance.sceneStep(cid, 'recover_all_fail',
        level: LogLevel.error, fields: {'attempts': 4});

    // **iOS SIGKILL 兜底**: 4 次 checkLocalPort 全 fail + ports 真死 (Connection
    // refused), 说明 Node.js 真的被杀了. 之前 d5c5f17 加的 Swift didBecomeActive
    // ping 在「先后台再锁屏」场景不可靠 (深后台 MethodChannel 可能短暂断,
    // ping 完了 onNodeExit 也传不到 Dart), 表现为:
    //   - 8 秒后 finalNodeIsRunning 仍 = true (log 实证)
    //   - 4 次 checkLocalPort 全 Connection refused
    // 不能依赖 Swift 通知, 必须 Dart 端主动检测 + 强制重启.
    //
    // **强制重启流程**:
    //   1. resetPlatformStateForRestart() 调平台 stopNodeJS, Swift 端
    //      isRunning 清 false (平台 stopNodeJS 调 invokeMethod 'stopNodeJS'
    //      → Swift 端 isRunning=false). **不**停 HTTP server.
    //   2. 短 wait 200ms 等 Swift 异步处理 stopNodeJS invokeMethod
    //   3. startNodeJS() 调 Swift 启动新 Node.js (Swift 端 isRunning=false
    //      会接受启动). 新 Node.js 启动后 onCatPawOpenPort 通过一直跑着的
    //      HTTP server 通知 Dart 新端口.
    //   4. 等 1s 让端口同步, 然后 reloadSourceViaManagementPort 重新加载源.
    AppLog.instance.sceneStep(cid, 'force_restart_triggered',
        level: LogLevel.warn,
        fields: {
          'reason':
              '4 次 checkLocalPort 全 fail + ports 真死, iOS SIGKILL 场景, 强制重启 Node.js',
          'beforeIsRunning': NodeJSManager.instance.isRunning,
          'beforeSpiderPort': NodeJSManager.instance.spiderPort,
          'beforeMgmtPort': NodeJSManager.instance.managementPort,
        });

    if (NodeJSManager.instance.isRunning) {
      // isRunning 卡 true, 必须先清状态才能调 startNodeJS
      NodeJSManager.instance.resetPlatformStateForRestart();
      // Swift invokeMethod 是异步的, 等 200ms 让 Swift 端处理 stopNodeJS
      await Future.delayed(const Duration(milliseconds: 200));
    }

    final restartStart = DateTime.now();
    final restartOk = await NodeJSManager.instance.startNodeJS();
    AppLog.instance.sceneStep(
      cid,
      restartOk ? 'force_restart_start_ok' : 'force_restart_start_fail',
      elapsedMs: DateTime.now().difference(restartStart).inMilliseconds,
      level: restartOk ? LogLevel.info : LogLevel.error,
      fields: {'ok': restartOk},
    );
    if (!restartOk) {
      return false;
    }

    // 等新端口同步 (新 Node.js 启动后会通过 onCatPawOpenPort 通知 Dart)
    await Future.delayed(const Duration(milliseconds: 1000));
    final newMgmtPort = NodeJSManager.instance.managementPort;
    final newSpiderPort = NodeJSManager.instance.spiderPort;
    AppLog.instance.sceneStep(cid, 'force_restart_ports_synced',
        fields: {
          'newSpiderPort': newSpiderPort,
          'newMgmtPort': newMgmtPort,
          'waitedMs': 1000,
        });
    if (newMgmtPort <= 0) {
      AppLog.instance.sceneStep(cid, 'force_restart_no_mgmt_port',
          level: LogLevel.error,
          fields: {
            'reason':
                'startNodeJS 返 true 但 1s 后 mgmt port 仍未同步, 重启失败',
          });
      return false;
    }

    // 用新 mgmt port 重新加载源
    final reloadStart = DateTime.now();
    final reloaded = await NodeJSManager.instance
        .reloadSourceViaManagementPort(newMgmtPort);
    AppLog.instance.sceneStep(
      cid,
      reloaded ? 'force_restart_reload_ok' : 'force_restart_reload_fail',
      elapsedMs: DateTime.now().difference(reloadStart).inMilliseconds,
      level: reloaded ? LogLevel.info : LogLevel.warn,
      fields: {'ok': reloaded, 'managementPort': newMgmtPort},
    );
    if (reloaded) {
      _nodeJSStarted = true;
      AppLog.instance.sceneStep(cid, 'force_restart_recovered',
          level: LogLevel.info,
          fields: {
            'newSpiderPort': NodeJSManager.instance.spiderPort,
            'newMgmtPort': newMgmtPort,
          });
      return true;
    }
    // 源 reload 失败, 但 Node.js 重启成功了, 算部分恢复
    _nodeJSStarted = true;
    return true;
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
