import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'common/theme.dart';
import 'common/constants.dart';
import 'services/app_state.dart';
import 'services/app_log.dart';
import 'services/background_service.dart';
import 'services/nodejs_manager.dart';
import 'pages/home/view.dart';
import 'pages/live/view.dart';
import 'pages/live/controller.dart';
import 'pages/history/view.dart';
import 'pages/favorites/view.dart';
import 'pages/settings/view.dart';
import 'pages/search/view.dart';
import 'pages/search/controller.dart';
import 'pages/settings/controller.dart';
import 'router/app_pages.dart';
import 'widgets/video_player_pip.dart';

class TVBoxApp extends StatelessWidget {
  const TVBoxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'TVBox',
      theme: AppTheme.darkTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      // 把 NavigatorState 暴露给 VideoPlayerPip，让画中画能插入到顶层 Overlay
      navigatorKey: VideoPlayerPip.navigatorKey,
      home: const ContentView(),
      getPages: AppPages.pages,
      debugShowCheckedModeBanner: false,
    );
  }
}

/// 主内容视图 - 对应 Swift ContentView
/// 管理三种状态：设置页 / 加载页 / 主页
class ContentView extends StatefulWidget {
  const ContentView({super.key});

  @override
  State<ContentView> createState() => _ContentViewState();
}

class _ContentViewState extends State<ContentView>
    with WidgetsBindingObserver {
  int _selectedTab = 0;
  bool _hasSavedConfig = false;
  bool _showSearch = false;
  // 防止 ever() 回调重入 - 在回调内部清空 pendingSearchKeyword 时会再次触发 ever()
  bool _isProcessingSearchKeyword = false;

  // 设置页表单
  final _vodUrlController = TextEditingController();
  final _liveUrlController = TextEditingController();
  bool _setupInputTargetIsVod = true;
  bool _isLoadingConfig = false;
  String? _configError;

  // 搜索控制器
  TvSearchController? _searchVM;

  // 设置控制器（多仓库选择）
  SettingsController? _settingsVM;

  /// 上一次 lifecycle state (用于记录 from→to 转换)
  AppLifecycleState? _lastLifecycleState;
  DateTime? _lastLifecycleChangeAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _searchVM = Get.find<TvSearchController>();
    _settingsVM = Get.put(SettingsController());
    // 对应 Swift: .onChange(of: appState.pendingSearchKeyword)
    // 使用 ever 监听 pendingSearchKeyword 变化，触发搜索 overlay
    // 注意: 在回调内部清空 pendingSearchKeyword 会再次触发 ever()，必须用 guard 防止重入
    final appState = Get.find<AppState>();
    ever(appState.pendingSearchKeyword, (String? keyword) {
      // 防止重入: 清空 pendingSearchKeyword.value = null 会再次触发此回调
      if (_isProcessingSearchKeyword) return;
      if (keyword != null && keyword.isNotEmpty && mounted) {
        _isProcessingSearchKeyword = true;
        _searchVM?.keyword.value = keyword;
        // 清空 pendingSearchKeyword，对应 Swift: appState.pendingSearchKeyword = nil
        appState.pendingSearchKeyword.value = null;
        setState(() {
          _showSearch = true;
        });
        _isProcessingSearchKeyword = false;
        // 对应 Swift: 延迟搜索到下一帧，避免在 build 阶段触发 setState
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _searchVM?.search();
        });
      }
    });
    _loadSavedConfig();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _vodUrlController.dispose();
    _liveUrlController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 对应 Swift onChange(of: scenePhase) - 应用恢复前台时检查服务
    final from = _lastLifecycleState;
    final now = DateTime.now();
    final prevAt = _lastLifecycleChangeAt;
    final sincePrevMs =
        prevAt == null ? null : now.difference(prevAt).inMilliseconds;

    AppLog.instance.lifecycle(
      'didChange',
      from: from,
      to: state,
      source: 'ContentView',
      fields: {
        'isConfigLoaded': Get.find<AppState>().isConfigLoaded.value,
        if (sincePrevMs != null) 'sincePrevMs': sincePrevMs,
      },
    );

    _lastLifecycleState = state;
    _lastLifecycleChangeAt = now;

    if (state == AppLifecycleState.resumed) {
      final appState = Get.find<AppState>();
      AppLog.instance.lifecycle(
        'trigger_handleSceneActive',
        to: state,
        source: 'ContentView.resumed',
        fields: {
          'reason': 'AppLifecycleState.resumed → handleSceneActive',
        },
      );
      appState.handleSceneActive();
    }
  }

  /// 对应 Swift onAppear - 加载已保存的配置
  Future<void> _loadSavedConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final savedVodUrl = prefs.getString(AppConstants.apiUrl) ?? '';
    final savedLiveUrl = prefs.getString(AppConstants.liveApiUrl) ?? '';

    if (savedVodUrl.isNotEmpty) {
      _hasSavedConfig = true;
      _vodUrlController.text = savedVodUrl;
      _liveUrlController.text = savedLiveUrl;
      final appState = Get.find<AppState>();
      await appState.loadConfigWithLive(
        vodUrl: savedVodUrl,
        liveUrl: savedLiveUrl,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = Get.find<AppState>();

    return Obx(() {
      final phase = appState.loadingPhase.value;

      // 对应 Swift: if appState.isConfigLoaded → mainTabView
      // else if hasSavedConfig && loadingPhase != .idle → loadingView
      // else → setupView
      Widget currentChild;
      if (appState.isConfigLoaded.value) {
        currentChild = _buildMainTabView();
      } else if (_hasSavedConfig && phase != LoadingPhase.idle) {
        currentChild = _buildLoadingView();
      } else {
        currentChild = _buildSetupView();
      }

      return Stack(
        children: [
          currentChild,
          // 对应 Swift: .overlay(alignment: .top) { networkStatusBanner }
          _buildNetworkStatusBanner(),
        ],
      );
    });
  }

  // ============================================================
  // 加载视图 - 对应 Swift loadingView
  // ============================================================

  /// Node.js 下载进度条
  Widget _buildNodeJSDownloadProgress() {
    final mgr = NodeJSManager.instance;
    return ValueListenableBuilder<double?>(
      valueListenable: mgr.nodeDownloadProgress,
      builder: (ctx, progress, _) {
        final p = progress ?? 0.0;
        return SizedBox(
          width: 320,
          child: Column(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: p > 0 ? p : null,
                  minHeight: 6,
                  backgroundColor: Colors.white.withValues(alpha: 0.1),
                  valueColor: const AlwaysStoppedAnimation<Color>(
                      AppTheme.accentColor),
                ),
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<String?>(
                valueListenable: mgr.nodeDownloadStatus,
                builder: (ctx2, status, _) {
                  String text;
                  if (status == 'downloading') {
                    text = '下载中... ${(p * 100).toStringAsFixed(0)}%';
                  } else if (status == 'extracting') {
                    text = '解压中...';
                  } else if (status == 'done') {
                    text = '完成！';
                  } else if (status == 'error') {
                    text = '下载失败';
                  } else {
                    text = '准备下载...';
                  }
                  return Text(
                    text,
                    style: const TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption,
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLoadingView() {
    final appState = Get.find<AppState>();

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF0F0F0F),
            Color(0xFF141414),
            Color(0xFF0F0F0F),
          ],
        ),
      ),
      child: SafeArea(
        child: Center(
          child: Obx(() {
            final phase = appState.loadingPhase.value;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Logo
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [
                        AppTheme.accentColor,
                        AppTheme.accentLightColor,
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.accentColor.withValues(alpha: 0.4),
                        blurRadius: 20,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.play_circle_filled,
                    size: 50,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: AppTheme.spacingXL),
                const Text(
                  'TVBox',
                  style: TextStyle(
                    fontSize: 48,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: AppTheme.spacingSM + AppTheme.spacingMD),
                // 加载中 / 错误状态 - 对应 Swift loadingView 中的条件判断
                if (phase.isLoading)
                  Column(
                    children: [
                      if (phase == LoadingPhase.downloadingNodeJS)
                        _buildNodeJSDownloadProgress()
                      else
                        const CircularProgressIndicator(
                          color: AppTheme.accentColor,
                        ),
                      const SizedBox(height: AppTheme.spacingLG),
                      Text(
                        phase.description,
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: AppTheme.fontSubhead,
                        ),
                      ),
                    ],
                  )
                else if (phase.isFailed)
                  Column(
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: Colors.red,
                        size: 48,
                      ),
                      const SizedBox(height: AppTheme.spacingMD),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          appState.phaseDisplayText,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: AppTheme.fontSubhead,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: AppTheme.spacingLG),
                      ElevatedButton(
                        onPressed: () {
                          // 对应 Swift onRetry: { hasSavedConfig = false }
                          setState(() {
                            _hasSavedConfig = false;
                          });
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.accentColor,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('重试'),
                      ),
                    ],
                  ),
              ],
            );
          }),
        ),
      ),
    );
  }

  // ============================================================
  // 设置视图 - 对应 Swift setupView
  // ============================================================

  Widget _buildSetupView() {
    final appState = Get.find<AppState>();

    return Material(
      color: const Color(0xFF0F0F0F),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF0F0F0F),
              Color(0xFF141414),
              Color(0xFF0F0F0F),
            ],
          ),
        ),
        child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 30),
            child: Column(
              children: [
                const SizedBox(height: 60),
                // Logo
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [
                        AppTheme.accentColor,
                        AppTheme.accentLightColor,
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.accentColor.withValues(alpha: 0.4),
                        blurRadius: 20,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.play_circle_filled,
                    size: 50,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: AppTheme.spacingXL),
                const Text(
                  'TVBox',
                  style: TextStyle(
                    fontSize: 48,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: AppTheme.spacingSM),
                const Text(
                  '极致视听 · 简洁至上',
                  style: TextStyle(
                    fontSize: AppTheme.fontSubhead,
                    color: AppTheme.textSecondary,
                    letterSpacing: 4,
                  ),
                ),
                const SizedBox(
                    height: AppTheme.spacingXXL + AppTheme.spacingSM),
                // 接口配置标题
                Container(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.only(left: AppTheme.spacingXS),
                  child: const Text(
                    '接口配置',
                    style: TextStyle(
                      fontSize: AppTheme.fontHeadline,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(height: AppTheme.spacingMD),
                // 点播接口地址 - 对应 Swift vodApiUrl TextField
                Container(
                  decoration: BoxDecoration(
                    color: AppTheme.backgroundSecondary,
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(color: AppTheme.borderLight),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 14),
                      const Icon(Icons.link,
                          color: AppTheme.accentColor, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _vodUrlController,
                          style: const TextStyle(
                              color: AppTheme.textPrimary),
                          decoration: const InputDecoration(
                            hintText: '请输入点播接口地址 (URL)',
                            hintStyle: TextStyle(
                                color: AppTheme.textTertiary),
                            border: InputBorder.none,
                            contentPadding:
                                EdgeInsets.symmetric(vertical: 14),
                          ),
                          keyboardType: TextInputType.url,
                          onTap: () {
                            _setupInputTargetIsVod = true;
                          },
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.content_paste,
                            color: AppTheme.accentColor, size: 20),
                        onPressed: _pasteFromClipboard,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppTheme.spacingMD),
                // 直播接口地址 - 对应 Swift liveApiUrl TextField
                Container(
                  decoration: BoxDecoration(
                    color: AppTheme.backgroundSecondary,
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(color: AppTheme.borderLight),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 14),
                      const Icon(Icons.tv,
                          color: AppTheme.accentColor, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _liveUrlController,
                          style: const TextStyle(
                              color: AppTheme.textPrimary),
                          decoration: const InputDecoration(
                            hintText: '请输入直播接口地址 (URL，可留空跟随点播)',
                            hintStyle: TextStyle(
                                color: AppTheme.textTertiary),
                            border: InputBorder.none,
                            contentPadding:
                                EdgeInsets.symmetric(vertical: 14),
                          ),
                          keyboardType: TextInputType.url,
                          onTap: () {
                            _setupInputTargetIsVod = false;
                          },
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.content_paste,
                            color: AppTheme.accentColor, size: 20),
                        onPressed: _pasteFromClipboard,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppTheme.spacingXXL),
                // 确认按钮 - 对应 Swift "开启影音之旅" Button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isLoadingConfig
                        ? null
                        : () => _submitConfig(appState),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.accentColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          vertical: AppTheme.spacingLG),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                    child: _isLoadingConfig
                        ? Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Obx(() {
                                final phase = appState.loadingPhase.value;
                                return Text(
                                  phase.isLoading
                                      ? phase.description
                                      : '正在解析配置...',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16),
                                );
                              }),
                            ],
                          )
                        : const Text(
                            '开启影音之旅',
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16),
                          ),
                  ),
                ),
                // 最近使用 - 对应 Swift apiHistory
                if (_settingsVM != null &&
                    _settingsVM!.apiHistory.isNotEmpty)
                  Obx(() {
                    final history = _settingsVM!.apiHistory;
                    if (history.isEmpty) return const SizedBox.shrink();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: AppTheme.spacingXXL),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppTheme.spacingXS),
                          child: const Text(
                            '最近使用',
                            style: TextStyle(
                              fontSize: AppTheme.fontCaption,
                              color: AppTheme.textTertiary,
                            ),
                          ),
                        ),
                        const SizedBox(height: AppTheme.spacingMD),
                        ...history.take(3).map((url) => Padding(
                              padding: const EdgeInsets.only(
                                  bottom: AppTheme.spacingMD),
                              child: GestureDetector(
                                onTap: () {
                                  if (_setupInputTargetIsVod) {
                                    _vodUrlController.text = url;
                                  } else {
                                    _liveUrlController.text = url;
                                  }
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 10,
                                      horizontal: AppTheme.spacingLG),
                                  decoration: BoxDecoration(
                                    color: AppTheme.backgroundSecondary,
                                    borderRadius:
                                        BorderRadius.circular(10),
                                    border: Border.all(
                                        color: AppTheme.borderLight,
                                        width: 0.5),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                          Icons
                                              .history_rounded,
                                          size: AppTheme.fontCaption,
                                          color:
                                              AppTheme.textSecondary),
                                      const SizedBox(
                                          width: AppTheme.spacingSM),
                                      Expanded(
                                        child: Text(
                                          url,
                                          style: const TextStyle(
                                            fontSize:
                                                AppTheme.fontCaption,
                                            color:
                                                AppTheme.textSecondary,
                                          ),
                                          maxLines: 1,
                                          overflow:
                                              TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const Icon(Icons.chevron_right,
                                          size: 8,
                                          color: AppTheme.textTertiary),
                                    ],
                                  ),
                                ),
                              ),
                            )),
                      ],
                    );
                  }),
                // 错误信息 - 对应 Swift settingsVM.configError
                if (_configError != null) ...[
                  const SizedBox(height: AppTheme.spacingLG),
                  Container(
                    padding: const EdgeInsets.all(AppTheme.spacingMD),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: Colors.red.withValues(alpha: 0.3),
                          width: 0.5),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline,
                            color: Colors.red, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _configError!,
                            style: const TextStyle(
                                color: Colors.red,
                                fontSize: AppTheme.fontCaption),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 50),
              ],
            ),
          ),
        ),
        ),
      ),
    );
  }

  /// 提交配置 - 对应 Swift settingsVM.loadConfig()
  Future<void> _submitConfig(AppState appState) async {
    final vodUrl = _vodUrlController.text.trim();
    final liveUrl = _liveUrlController.text.trim();

    if (vodUrl.isEmpty) {
      setState(() {
        _configError = '请输入点播接口地址';
      });
      return;
    }

    setState(() {
      _isLoadingConfig = true;
      _configError = null;
    });

    // 保存配置 URL
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.apiUrl, vodUrl);
    if (liveUrl.isNotEmpty) {
      await prefs.setString(AppConstants.liveApiUrl, liveUrl);
    }

    try {
      await appState.loadConfigWithLive(
        vodUrl: vodUrl,
        liveUrl: liveUrl.isEmpty ? null : liveUrl,
      );

      if (appState.isConfigLoaded.value) {
        // 加载成功 - applyLoadedConfigState 已在 loadConfigWithLive 中调用
        if (_settingsVM != null) {
          await _settingsVM!.addToApiHistory(vodUrl);
        }
      } else {
        setState(() {
          _isLoadingConfig = false;
          _configError = appState.configLoadError.value ?? '配置加载失败';
        });
      }
    } catch (e) {
      setState(() {
        _isLoadingConfig = false;
        _configError = e.toString();
      });
    }
  }

  /// 从剪贴板粘贴 - 对应 Swift readPasteboardText()
  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      if (_setupInputTargetIsVod) {
        _vodUrlController.text = data.text!;
      } else {
        _liveUrlController.text = data.text!;
      }
    }
  }

  // ============================================================
  // 主标签视图 - 对应 Swift mainTabView
  // ============================================================

  final List<Widget> _tabPages = [
    const HomePage(),
    const LivePage(),
    const HistoryPage(),
    const FavoritesPage(),
    const SettingsPage(),
  ];

  Widget _buildMainTabView() {
    final appState = Get.find<AppState>();

    // 对应 Swift: .sheet(isPresented: $appState.showAboutOnLaunch)
    _handleShowAboutOnLaunch(appState);

    return Scaffold(
      body: Stack(
        children: [
          // 全局背景层 - 对应 TV-release CustomWallView
          // 4 个内置渐变 + 用户上传自定义图片, 通过 BackgroundService 切换
          // 5 个 tab 页背景透明 (后述) 让其透出
          Positioned.fill(
            child: BackgroundService.instance.buildBackground(overlayAlpha: 0.3),
          ),
          IndexedStack(
            index: _selectedTab,
            children: _tabPages,
          ),
          // 搜索页 - 对应 Swift .sheet(isPresented: $showSearch)
          if (_showSearch)
            Positioned.fill(
              child: Material(
                color: const Color(0xFF0F0F0F),
                child: SearchPage(
                  onClose: () {
                    setState(() {
                      _showSearch = false;
                    });
                  },
                ),
              ),
            ),
        ],
      ),
      // 浮动导航栏 - 对应 Swift floatingNavBar
      bottomNavigationBar: Container(
        margin: const EdgeInsets.fromLTRB(32, 0, 32, 4),
        decoration: BoxDecoration(
          // 半透明色, 让 BackgroundService 全局背景层透出
          // 替换原 Color(0xFF1C1C1E) (完全不透明) 造成的"黑色板块"问题
          color: AppTheme.backgroundNavBar,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.08),
            width: 0.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 10,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _navItem(Icons.home_outlined, Icons.home, '首页', 0),
                _navItem(Icons.tv_outlined, Icons.tv, '直播', 1),
                _navItem(
                    Icons.schedule_outlined, Icons.schedule, '历史', 2),
                _navItem(
                    Icons.favorite_border, Icons.favorite, '收藏', 3),
                _navItem(
                    Icons.settings_outlined, Icons.settings, '设置', 4),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 处理 showAboutOnLaunch - 启动时显示免责声明
  /// 对应 Swift .sheet(isPresented: $appState.showAboutOnLaunch)
  /// 用户可勾选"不再提示"，勾选后持久化到 SharedPreferences
  void _handleShowAboutOnLaunch(AppState appState) {
    if (appState.showAboutOnLaunch.value) {
      appState.showAboutOnLaunch.value = false;
      // 延迟显示，避免在 build 中直接弹窗
      Future.microtask(() {
        if (mounted) {
          _showDisclaimerDialog();
        }
      });
    }
  }

  /// 显示免责声明对话框
  Future<void> _showDisclaimerDialog() async {
    final prefs = await SharedPreferences.getInstance();
    // 若用户已勾选"不再提示"，则跳过
    if (prefs.getBool(AppConstants.disclaimerAccepted) == true) {
      return;
    }

    if (!mounted) return;

    bool dontShowAgain = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            backgroundColor: AppTheme.backgroundSecondary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusLG),
            ),
            title: const Row(
              children: [
                Icon(Icons.gavel,
                    color: AppTheme.accentColor, size: 22),
                SizedBox(width: 8),
                Text(
                  '免责声明',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontTitle3,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      '使用本软件前，请仔细阅读以下免责声明。点击"同意"即表示您已阅读、理解并同意接受全部条款约束。',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: AppTheme.fontFootnote,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 12),
                    _DisclaimerText(
                      title: '一、定义与适用范围',
                      body:
                          '1.1 "本软件"指 TVBox（及其各发行版本、衍生版本，下同）应用程序，包括其提供的全部功能模块、界面、文档及更新。\n'
                          '1.2 "用户"指下载、安装、运行或以其他方式使用本软件的任何自然人、法人或非法人组织。\n'
                          '1.3 本免责声明（"本声明"）构成用户使用本软件之先决条件。用户安装、启动或继续使用本软件，即视为已阅读、理解并同意受本声明全部条款之约束。若用户不同意本声明之任何条款，应立即停止使用本软件并卸载。',
                    ),
                    _DisclaimerText(
                      title: '二、软件性质与功能说明',
                      body:
                          '2.1 本软件为通用型媒体播放与浏览工具（"壳"/"播放器"），其功能包括但不限于：播放用户自行配置或合法获取的视听内容、浏览视频分类与详情、观看直播、搜索影片、管理播放历史与收藏夹。\n'
                          '2.2 本软件不生产、不聚合、不存储、不向用户提供任何影视、音乐、漫画、小说或其他受著作权法保护的内容。本软件不内置、不预置、不推荐任何具体的内容源、资源站、接口地址或爬虫规则。用户可见的全部内容来源均来自用户本人配置的接口、地址、脚本或用户自行连接之第三方服务。\n'
                          '2.3 本软件支持用户自行配置视频源接口地址（含 Spider/NodeJS 类型源），用户须自行获取并配置合法的接口地址。本软件不代为提供、不托管、不保证上述接口或第三方服务之可用性、合法性或内容合规性。',
                    ),
                    _DisclaimerText(
                      title: '三、不提供内容与用户自行配置',
                      body:
                          '3.1 本软件在交付时未内置任何可访问的影视、音乐、漫画、小说等内容目录或播放源。用户若需通过本软件访问任何外部内容，须自行在软件内配置接口地址、源规则或连接自有/第三方服务。\n'
                          '3.2 用户对自身所配置的接口、源、脚本、第三方服务地址及通过上述方式获取或播放的全部内容负完全责任。本软件开发者、发行方、贡献者（合称"提供方"）不对用户配置之来源的合法性、准确性、安全性、是否侵犯第三方知识产权或其它权利承担任何责任。\n'
                          '3.3 用户理解并同意：通过本软件可访问之内容可能涉及受著作权、邻接权或其他法律保护之作品。用户应确保其配置之来源及对内容的使用符合其所在法域之法律法规及相关权利人之授权。提供方不对用户因使用本软件访问、播放、下载或传播任何内容而可能产生的侵权或违规后果负责。',
                    ),
                    _DisclaimerText(
                      title: '四、第三方服务与接口',
                      body:
                          '4.1 本软件允许用户自行配置并连接第三方视频源接口与直播服务。该等第三方服务由其各自运营方独立提供，其服务条款、隐私政策、内容合规性及可用性均与提供方无关。\n'
                          '4.2 提供方不对任何第三方服务之可用性、稳定性、安全性、合法性、内容合规性作出明示或默示的保证，亦不对因使用或无法使用该等第三方服务所导致的任何直接、间接、附带、后果性或惩罚性损害承担责任。\n'
                          '4.3 本软件中可能包含指向第三方网站、文档或资源的链接或引用，仅为便利用户而设。提供方不控制该等第三方资源，不对其内容或隐私做法负责，用户访问该等资源之风险由用户自行承担。',
                    ),
                    _DisclaimerText(
                      title: '五、知识产权与版权合规',
                      body:
                          '5.1 本软件（包括但不限于代码、界面、文档、商标与标识）之知识产权归提供方或相应权利人所有。用户依本声明及适用开源许可证获得之权利限于使用本软件，不得用于反向工程、再发行侵权版本、移除权利声明或违反许可证之用途。\n'
                          '5.2 用户通过本软件访问、播放或获取之视听、图文等内容，其著作权、邻接权及其他权利归各自权利人所有。用户不得利用本软件从事任何侵犯他人知识产权或违反所在法域法律法规之行为。提供方不对用户使用本软件所涉之版权合规性负责，且有权在知悉明显侵权或违法使用之情形下采取合理措施（包括但不限于配合权利人或监管要求）。',
                    ),
                    _DisclaimerText(
                      title: '六、免责与责任限制',
                      body:
                          '6.1 在法律允许的最大范围内，本软件按"现状"和"可用性"提供，提供方不对本软件作任何明示、默示或法定之保证，包括但不限于对适销性、特定用途适用性、不侵权、安全性、稳定性、无错误或不间断运行之保证。\n'
                          '6.2 除法律明确规定不得排除之责任外，提供方在任何情况下均不对因使用或无法使用本软件、因本声明、因用户配置之来源或第三方服务、或因本软件与任何硬件/软件/网络之交互而产生的下列损害承担责任：直接、间接、附带、后果性、惩罚性、特殊或类似损害；利润、数据、商誉或业务机会之损失；人身伤害或财产损失；或任何其他基于合同、侵权（包括过失）、严格责任、保证或其他法律理论之索赔，无论提供方是否被告知该等损害之可能性。\n'
                          '6.3 即或提供方被认定需承担任何责任，该责任之总额亦以用户为获得本软件所实际支付之金额为上限（若本软件系免费提供，则该上限为零）。前述限制在适用法律允许之范围内适用。',
                    ),
                    _DisclaimerText(
                      title: '七、无担保声明',
                      body:
                          '7.1 提供方不保证本软件无缺陷、无错误、无中断、无病毒或其它有害成分；不保证本软件之结果准确、可靠或满足用户之特定目的。\n'
                          '7.2 本软件可能随版本更新而变更功能、界面或行为，提供方不保证向后兼容或长期维持某一功能。用户应自行备份重要配置与数据。',
                    ),
                    _DisclaimerText(
                      title: '八、用户义务与禁止行为',
                      body:
                          '8.1 用户应遵守其所在国家/地区之全部适用法律、法规及监管要求，并应遵守其通过本软件所连接之第三方服务之条款与政策。\n'
                          '8.2 用户不得利用本软件从事以下行为（包括但不限于）：侵犯他人知识产权、隐私权或其它合法权益；传播违法、淫秽、暴力、欺诈或侵权内容；破坏或干扰本软件、第三方服务或网络之正常运行；未经授权访问他人系统或数据；将本软件用于任何非法用途或与本声明相悖之用途。\n'
                          '8.3 用户违反上述义务或法律法规而导致任何索赔、处罚或责任的，由用户自行承担；若导致提供方遭受损失或对第三方承担责任的，用户应赔偿提供方之全部损失并使之免受损害。',
                    ),
                    _DisclaimerText(
                      title: '九、隐私与数据',
                      body:
                          '9.1 本软件可能收集、存储或处理与使用相关的数据（如配置、日志、缓存等），具体以本软件之隐私政策或相关说明为准。用户使用本软件即表示同意该等收集与处理（在适用法律要求之范围内）。\n'
                          '9.2 用户通过本软件配置之接口、地址、账号等信息可能被本软件用于请求第三方服务。提供方不对用户向第三方披露之信息或第三方对数据之使用负责。用户应自行评估并承担向第三方提供信息之风险。',
                    ),
                    _DisclaimerText(
                      title: '十、开源组件与许可',
                      body:
                          '10.1 本软件可能包含以开源许可证发布的第三方组件。该等组件之著作权归其各自作者所有，用户使用本软件即间接使用该等组件，须遵守各组件所适用之开源许可证（如 MIT、Apache-2.0、GPL 等）。本声明不影响该等许可证赋予用户之权利与义务。\n'
                          '10.2 本软件若整体或部分以开源形式提供，用户对源码之使用、修改与再分发须遵守该开源项目所标明之许可证及本声明之约束。',
                    ),
                    _DisclaimerText(
                      title: '十一、适用法律与争议解决',
                      body:
                          '11.1 本声明之订立、效力、解释、履行及争议解决均适用中华人民共和国法律（为本声明之目的，不包括冲突法规则）；若用户位于中华人民共和国以外，在不与当地强制性法律相抵触之前提下，仍可适用中华人民共和国法律作为补充解释。\n'
                          '11.2 因本声明或使用本软件而产生之任何争议，双方应尽量友好协商解决；协商不成的，任何一方可将争议提交至提供方主营业地有管辖权之人民法院诉讼解决。',
                    ),
                    _DisclaimerText(
                      title: '十二、条款变更与可分割性',
                      body:
                          '12.1 提供方有权根据需要修订本声明。修订后的声明将在本软件内或通过本软件之发布渠道公布；若用户在本声明修订后继续使用本软件，即视为接受修订后的声明。若用户不同意修订内容，应停止使用本软件并卸载。\n'
                          '12.2 若本声明之任何条款被有管辖权的裁判机构认定为无效或不可执行，该条款应在必要之最小范围内修改以使其有效并可执行，且不影响本声明其余条款之效力。',
                    ),
                    _DisclaimerText(
                      title: '十三、联系与生效',
                      body:
                          '13.1 用户对本声明有任何疑问，可通过本软件之关于页、发布页或官方公布的渠道与提供方联系（若提供方提供该等渠道）。\n'
                          '13.2 本声明自用户首次安装或使用本软件时起生效，并持续适用于用户对本软件之使用，直至用户卸载本软件且不再使用为止；其中涉及责任限制、免责、争议解决等条款在用户停止使用后仍对既往使用行为具有效力。',
                    ),
                    SizedBox(height: 8),
                    Text(
                      '—— 以上为《TVBox 免责声明》之全部条款。请在使用本软件前仔细阅读。使用即表示您已理解并同意受其约束。',
                      style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // 不再提示勾选框
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: dontShowAgain,
                        onChanged: (v) {
                          setDialogState(() {
                            dontShowAgain = v ?? false;
                          });
                        },
                        activeColor: AppTheme.accentColor,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      ),
                      const Text(
                        '不再提示',
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: AppTheme.fontFootnote,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () {
                          // 不同意则退出应用
                          Navigator.pop(ctx);
                          SystemNavigator.pop();
                        },
                        child: const Text('不同意',
                            style:
                                TextStyle(color: AppTheme.textTertiary)),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () async {
                          if (dontShowAgain) {
                            await prefs.setBool(
                                AppConstants.disclaimerAccepted, true);
                          }
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.accentColor,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('同意'),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  /// 导航栏项 - 对应 Swift navBarItem
  Widget _navItem(
      IconData icon, IconData activeIcon, String label, int index) {
    final isSelected = _selectedTab == index;
    return GestureDetector(
      onTap: () {
        final prev = _selectedTab;
        setState(() {
          _selectedTab = index;
        });
        // **关键**：切走直播 tab 时通知 LiveController 暂停 / 隐藏，
        // 避免 IndexedStack 中 LivePage 持续在后台播放声音。
        // 切回时恢复可见 + 继续播放。
        if (Get.isRegistered<LiveController>()) {
          final live = Get.find<LiveController>();
          if (index == 1) {
            live.isLivePageVisible.value = true;
            live.resumePlayback();
          } else if (prev == 1) {
            live.isLivePageVisible.value = false;
            live.pausePlayback();
          }
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.accentColor.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isSelected ? activeIcon : icon,
              size: 18,
              color: isSelected
                  ? AppTheme.accentColor
                  : Colors.white.withValues(alpha: 0.35),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: isSelected
                    ? AppTheme.accentColor
                    : Colors.white.withValues(alpha: 0.35),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 网络状态横幅 - 对应 Swift networkStatusBanner
  // ============================================================

  Widget _buildNetworkStatusBanner() {
    final appState = Get.find<AppState>();

    return Obx(() {
      // 对应 Swift: if !networkMonitor.isConnected
      // 使用 connectivity_plus 的状态判断
      // 这里通过 appState 的网络状态来显示
      final isRetrying = appState.isRetryingConfig.value;
      // 当正在重试时显示网络横幅（表示之前断网过）
      if (!isRetrying) return const SizedBox.shrink();

      return Positioned(
        top: MediaQuery.of(context).padding.top + AppTheme.spacingSM,
        left: 0,
        right: 0,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.spacingLG,
              vertical: AppTheme.spacingSM,
            ),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: AppTheme.spacingSM,
                  offset: const Offset(0, AppTheme.spacingXS),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.wifi_off,
                    color: Colors.white, size: 16),
                const SizedBox(width: AppTheme.spacingSM),
                const Text(
                  '网络连接已断开',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: AppTheme.fontSubhead,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                // 对应 Swift: if appState.isRetryingConfig { ProgressView() }
                if (isRetrying) ...[
                  const SizedBox(width: AppTheme.spacingSM),
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    });
  }
}

/// 免责声明条款文本组件
class _DisclaimerText extends StatelessWidget {
  final String title;
  final String body;

  const _DisclaimerText({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontFootnote,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            body,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontCaption,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
