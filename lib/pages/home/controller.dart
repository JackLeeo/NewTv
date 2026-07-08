import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import '../../models/movie.dart';
import '../../models/movie_sort.dart';
import '../../services/api_config.dart';
import '../../services/app_log.dart';
import '../../services/app_state.dart';
import '../../services/source_service.dart';

class HomeController extends GetxController with WidgetsBindingObserver {
  final sorts = <SortData>[].obs;
  final selectedSort = Rx<SortData?>(null);
  final homeVideos = <Video>[].obs;
  final categoryVideos = <Video>[].obs;
  final isLoading = false.obs;
  final currentPage = 1.obs;
  final hasMore = true.obs;
  final errorMessage = Rx<String?>(null);
  final selectedFilters = <String, String>{}.obs;

  List<SortFilter> get currentFilters {
    final sortId = selectedSort.value?.id;
    if (sortId == null) return [];
    return sorts.firstWhereOrNull((s) => s.id == sortId)?.filters ?? [];
  }

  /// 当前显示的视频列表：对应 Swift contentArea 中的 viewModel.categoryVideos
  List<Video> get displayVideos => categoryVideos;

  /// Worker：监听 AppState.loadingPhase
  /// 用于后台/锁屏切回前台时，AppState.handleSceneActive 完成重连后
  /// 自动刷新首页数据（之前 dio socket 死连接，homeSourceBean 引用未变，
  /// ever 监听不会触发，导致页面数据陈旧且请求失败）
  Worker? _loadingPhaseWorker;
  LoadingPhase? _lastObservedPhase;

  @override
  void onInit() {
    super.onInit();
    // 监听 lifecycle：应用从后台/锁屏切回前台时强制重置 isLoading 并刷新
    // （旧 dio 的 in-flight 请求可能永远不返回，导致 isLoading 一直卡在 true，
    //  新 dio 的请求又因为 isLoading=true 被跳过，出现"点击无响应"）
    WidgetsBinding.instance.addObserver(this);

    // 监听主页源变化，自动重新加载
    ever(ApiConfig.instance.homeSourceBean, (source) {
      if (source != null) {
        refresh();
      }
    });

    // 监听 AppState 加载阶段：仅 reconnecting → completed 时刷新
    // 这样应用从后台/锁屏切回时，handleSceneActive 完成重连后会刷新数据
    // 首次启动的 completed 不触发，避免与 onInit 的 loadSorts 重复
    try {
      final appState = Get.find<AppState>();
      _lastObservedPhase = appState.loadingPhase.value;
      _loadingPhaseWorker = ever<LoadingPhase>(appState.loadingPhase, (phase) {
        final prev = _lastObservedPhase;
        _lastObservedPhase = phase;
        if (phase == LoadingPhase.completed &&
            prev == LoadingPhase.reconnecting) {
          refresh();
        }
      });
    } catch (_) {
      // AppState 还未注册（例如测试场景），忽略
    }

    // 首次加载
    loadSorts();
  }

  @override
  void onClose() {
    _loadingPhaseWorker?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }

  AppLifecycleState? _lastLifecycleState;
  DateTime? _lastLifecycleChangeAt;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 应用从后台/锁屏切回前台时：
    // 1. 强制重置 isLoading（之前后台挂起的请求可能永不返回，
    //    导致 isLoading 一直卡在 true，新点击的请求被跳过）
    // 2. 主动刷新数据（homeSourceBean 引用没变，ever 监听不会触发；
    //    且 iOS 后台时 dio socket 已死，旧 dio 不能再用）
    final from = _lastLifecycleState;
    final now = DateTime.now();
    final prevAt = _lastLifecycleChangeAt;
    final sincePrevMs =
        prevAt == null ? null : now.difference(prevAt).inMilliseconds;

    AppLog.instance.lifecycle(
      'didChange',
      from: from,
      to: state,
      source: 'HomeController',
      fields: {
        if (sincePrevMs != null) 'sincePrevMs': sincePrevMs,
        'homeSourceId': ApiConfig.instance.homeSourceBean.value?.id,
        'sortsCount': sorts.length,
        'homeVideosCount': homeVideos.length,
        'categoryVideosCount': categoryVideos.length,
        'isLoading': isLoading.value,
      },
    );

    _lastLifecycleState = state;
    _lastLifecycleChangeAt = now;

    if (state == AppLifecycleState.resumed) {
      isLoading.value = false;
      // 延后一帧执行，避免在 build 阶段触发 setState
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!isClosed) {
          AppLog.instance.lifecycle(
            'trigger_refresh',
            to: state,
            source: 'HomeController.resumed',
            fields: {
              'reason': 'AppLifecycleState.resumed → refresh()',
            },
          );
          refresh();
        }
      });
    }
  }

  Future<void> loadSorts() async {
    final source = ApiConfig.instance.homeSourceBean.value;
    if (source == null) return;

    isLoading.value = true;
    errorMessage.value = null;

    try {
      final result = await SourceService.instance.getSort(source);
      sorts.value = result.$1;
      homeVideos.value = result.$2;

      // 对应 Swift HomeView.task: loadSorts 后自动选择第一个分类
      if (selectedSort.value == null && sorts.isNotEmpty) {
        selectSort(sorts.first);
      }
    } catch (e) {
      errorMessage.value = _friendlyErrorMessage(e);
    }

    isLoading.value = false;
  }

  void selectSort(SortData sort) {
    selectedSort.value = sort;
    errorMessage.value = null;
    categoryVideos.clear();
    currentPage.value = 1;
    hasMore.value = true;
    selectedFilters.clear();

    _loadCategoryVideos(page: 1, sort: sort);
  }

  Future<void> _loadCategoryVideos({
    required int page,
    required SortData sort,
  }) async {
    final source = ApiConfig.instance.homeSourceBean.value;
    if (source == null || isLoading.value) return;

    isLoading.value = true;

    try {
      final filters = selectedFilters.isEmpty ? null : selectedFilters;
      final videos = await SourceService.instance.getList(
        source,
        sort,
        page: page,
        filters: filters,
      );

      // 分类切换过程中，丢弃旧请求结果
      if (selectedSort.value?.id != sort.id) {
        isLoading.value = false;
        return;
      }

      if (page == 1) {
        categoryVideos.value = videos;
      } else {
        categoryVideos.addAll(videos);
      }
      currentPage.value = page;
      hasMore.value = videos.isNotEmpty;
    } catch (e) {
      if (selectedSort.value?.id == sort.id) {
        errorMessage.value = _friendlyErrorMessage(e);
      }
    }

    isLoading.value = false;
  }

  Future<void> loadMore() async {
    if (!hasMore.value || isLoading.value) return;
    final sort = selectedSort.value;
    if (sort == null) return;

    final nextPage = currentPage.value + 1;
    await _loadCategoryVideos(page: nextPage, sort: sort);
  }

  void loadMoreIfNeeded(Video currentItem) {
    if (!hasMore.value || isLoading.value) return;
    if (categoryVideos.isEmpty) return;
    if (categoryVideos.last.id != currentItem.id) return;
    final sort = selectedSort.value;
    if (sort == null) return;

    final nextPage = currentPage.value + 1;
    _loadCategoryVideos(page: nextPage, sort: sort);
  }

  void selectFilter(String key, String value) {
    if (value.isEmpty) {
      selectedFilters.remove(key);
    } else {
      selectedFilters[key] = value;
    }

    categoryVideos.clear();
    currentPage.value = 1;
    hasMore.value = true;

    final sort = selectedSort.value;
    if (sort != null) {
      _loadCategoryVideos(page: 1, sort: sort);
    }
  }

  Future<void> refresh() async {
    currentPage.value = 1;
    hasMore.value = true;
    categoryVideos.clear();
    errorMessage.value = null;
    // 对应 Swift: 不重置 selectedSort，保留之前选中的分类
    await loadSorts();

    // 对应 Swift: loadSorts 后，尝试找到之前选中的分类并重新加载
    final sort = selectedSort.value;
    if (sort != null) {
      final matchedSort = sorts.firstWhereOrNull((s) => s.id == sort.id);
      if (matchedSort != null) {
        selectedSort.value = matchedSort;
        await _loadCategoryVideos(page: 1, sort: matchedSort);
      } else if (sorts.isNotEmpty) {
        selectSort(sorts.first);
      }
    } else if (sorts.isNotEmpty) {
      selectSort(sorts.first);
    }
  }

  String _friendlyErrorMessage(Object error) {
    final msg = error.toString();

    // DioException / 网络相关
    if (msg.contains('Connection refused') || msg.contains('connection refused')) {
      return '无法连接到本地服务，请稍后重试';
    }
    if (msg.contains('timed out') || msg.contains('TimedOut') || msg.contains('timeout')) {
      return '请求超时，请检查网络';
    }
    if (msg.contains('not connected') || msg.contains('No address associated')) {
      return '网络未连接，请检查网络设置';
    }
    if (msg.contains('Connection reset') || msg.contains('connection lost')) {
      return '网络连接中断，请稍后重试';
    }
    if (msg.contains('DNS') || msg.contains('dns')) {
      return 'DNS解析失败，请检查网络设置';
    }
    if (msg.contains('SocketException') || msg.contains('network')) {
      return '网络连接异常，请稍后重试';
    }

    return msg;
  }
}
