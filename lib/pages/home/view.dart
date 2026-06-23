import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../common/theme.dart';
import '../../services/api_config.dart';
import '../../services/app_state.dart';
import '../../models/source_bean.dart';
import '../../models/movie.dart';
import '../../widgets/vod_card.dart';
import '../../widgets/common_widgets.dart';
import '../webview/view.dart';
import 'controller.dart';

/// 首页 - 对应 Swift HomeView
class HomePage extends StatefulWidget {
  final VoidCallback? onSearchTap;

  const HomePage({super.key, this.onSearchTap});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final HomeController _controller = Get.put(HomeController());
  bool _isReconnecting = false;

  @override
  void initState() {
    super.initState();
    // 监听重连状态
    ever(ApiConfig.instance.isLoaded, (loaded) {
      if (loaded && _isReconnecting) {
        setState(() => _isReconnecting = false);
        _controller.refresh();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF0F0F0F), Color(0xFF141414), Color(0xFF0F0F0F)],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  _buildHeaderBar(),
                  _buildSearchBar(),
                  Obx(() {
                    if (_controller.sorts.isNotEmpty) {
                      return _buildCategoryTabBar();
                    }
                    return const SizedBox.shrink();
                  }),
                  Obx(() {
                    if (_controller.currentFilters.isNotEmpty) {
                      return _buildFilterBar();
                    }
                    return const SizedBox.shrink();
                  }),
                  Expanded(child: _buildContentArea()),
                ],
              ),
            ),
          ),
          // 重连覆盖层
          if (_isReconnecting) _buildReconnectingOverlay(),
        ],
      ),
    );
  }

  /// 重连覆盖层 - 对应 Swift isReconnecting overlay
  Widget _buildReconnectingOverlay() {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacingXXL,
          vertical: AppTheme.spacingLG,
        ),
        decoration: BoxDecoration(
          color: AppTheme.backgroundElevated,
          borderRadius: BorderRadius.circular(AppTheme.radiusMD),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: AppTheme.accentColor,
              ),
            ),
            const SizedBox(height: AppTheme.spacingMD),
            const Text(
              '正在重连服务...',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontSubhead,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingXL, AppTheme.spacingLG, AppTheme.spacingXL, AppTheme.spacingSM),
      child: Row(
        children: [
          PopupMenuButton<SourceBean>(
            offset: const Offset(0, 40),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusMD)),
            color: AppTheme.backgroundSecondary,
            onSelected: (source) {
              ApiConfig.instance.setHomeSource(source);
              _controller.refresh();
            },
            itemBuilder: (context) {
              return ApiConfig.instance.sourceBeanList.value.map((source) {
                return PopupMenuItem<SourceBean>(
                  value: source,
                  child: Row(
                    children: [
                      Text(source.name,
                          style: const TextStyle(color: AppTheme.textPrimary)),
                      if (source.key ==
                          ApiConfig.instance.homeSourceBean.value?.key)
                        const SizedBox(width: 8),
                      if (source.key ==
                          ApiConfig.instance.homeSourceBean.value?.key)
                        const Icon(Icons.check, color: AppTheme.accentColor, size: 16),
                    ],
                  ),
                );
              }).toList();
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Obx(() => Text(
                      ApiConfig.instance.homeSourceBean.value?.name ?? 'TVBox',
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )),
                const SizedBox(width: 4),
                const Icon(Icons.keyboard_arrow_down,
                    color: AppTheme.textTertiary, size: 16),
              ],
            ),
          ),
          const Spacer(),
          // 时钟 - 对应 Swift HomeClockView
          const _HomeClockView(),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacingLG, vertical: AppTheme.spacingXS),
      child: GestureDetector(
        onTap: () {
          if (widget.onSearchTap != null) {
            widget.onSearchTap!();
          } else {
            Get.toNamed('/search');
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: AppTheme.backgroundTertiary,
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Row(
            children: [
              Icon(Icons.search, color: AppTheme.textTertiary, size: 16),
              SizedBox(width: 8),
              Text(
                '搜索影片、演员、导演...',
                style: TextStyle(
                    color: AppTheme.textTertiary, fontSize: AppTheme.fontSubhead),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryTabBar() {
    return SizedBox(
      height: 40,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingLG),
        itemCount: _controller.sorts.length,
        itemBuilder: (context, index) {
          final sort = _controller.sorts[index];
          return Obx(() {
            final isSelected = _controller.selectedSort.value?.id == sort.id;
            return Padding(
              padding: const EdgeInsets.only(right: AppTheme.spacingSM),
              child: GestureDetector(
                onTap: () => _controller.selectSort(sort),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? AppTheme.accentColor.withValues(alpha: 0.12)
                        : AppTheme.backgroundTertiary,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    sort.name,
                    style: TextStyle(
                      color: isSelected
                          ? AppTheme.accentColor
                          : AppTheme.textSecondary,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
              ),
            );
          });
        },
      ),
    );
  }

  Widget _buildFilterBar() {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacingLG, vertical: AppTheme.spacingXS),
      child: Column(
        children: _controller.currentFilters.map((filter) {
          return Padding(
            padding: const EdgeInsets.only(bottom: AppTheme.spacingSM),
            child: Row(
              children: [
                SizedBox(
                  width: 36,
                  child: Text(
                    filter.name,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: AppTheme.fontCaption,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        SelectableChip(
                          title: '全部',
                          isSelected:
                              _controller.selectedFilters[filter.key] == null,
                          onTap: () =>
                              _controller.selectFilter(filter.key, ''),
                        ),
                        const SizedBox(width: AppTheme.spacingSM),
                        ...filter.values.map((value) {
                          return Padding(
                            padding: const EdgeInsets.only(
                                right: AppTheme.spacingSM),
                            child: SelectableChip(
                              title: value.n,
                              isSelected:
                                  _controller.selectedFilters[filter.key] ==
                                      value.v,
                              onTap: () => _controller.selectFilter(
                                  filter.key, value.v),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildContentArea() {
    return Obx(() {
      if (_controller.isLoading.value &&
          _controller.categoryVideos.isEmpty &&
          _controller.homeVideos.isEmpty) {
        return const AppLoading();
      }

      if (_controller.errorMessage.value != null &&
          _controller.categoryVideos.isEmpty) {
        final source = ApiConfig.instance.homeSourceBean.value;
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 索引服务特殊提示 - 对应 Swift isIndexSite 错误处理
              if (source != null && source.isIndexSite)
                const AppError(message: '该线路为索引服务，请点击影视跳转搜索')
              else
                AppError(
                  message: _controller.errorMessage.value!,
                  onRetry: () => _controller.refresh(),
                ),
              // 不支持的源类型提示 - 对应 Swift !isSupportedInSwift
              if (source != null && !source.isSupportedInSwift)
                Padding(
                  padding: const EdgeInsets.only(top: AppTheme.spacingSM),
                  child: Text(
                    '当前源类型: ${source.typeDescription}',
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: AppTheme.fontCaption,
                    ),
                  ),
                ),
            ],
          ),
        );
      }

      // 对应 Swift: 选中分类时显示 categoryVideos，否则显示 homeVideos
      final videos = _controller.displayVideos;

      return RefreshIndicator(
        color: AppTheme.accentColor,
        backgroundColor: AppTheme.backgroundSecondary,
        onRefresh: () => _controller.refresh(),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 自适应网格 - 对应 Swift adaptive(minimum: 120, maximum: 160)
            final cardMinWidth = 120.0;
            final crossAxisCount =
                (constraints.maxWidth / (cardMinWidth + AppTheme.cardSpacing))
                    .floor()
                    .clamp(2, 6);
            final cardWidth =
                (constraints.maxWidth - AppTheme.cardSpacing * (crossAxisCount - 1)) /
                    crossAxisCount;

            return GridView.builder(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.spacingXL,
                AppTheme.spacingMD,
                AppTheme.spacingXL,
                80, // 底部间距对应 Swift .padding(.bottom, 80)
              ),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                childAspectRatio: (cardWidth) / (cardWidth / 0.65 + 50),
                crossAxisSpacing: AppTheme.cardSpacing,
                mainAxisSpacing: AppTheme.cardSpacing,
              ),
              itemCount: videos.length + (_controller.hasMore.value && _controller.selectedSort.value != null ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= videos.length) {
                  // 对应 Swift: 使用 addPostFrameCallback 避免在 build 阶段触发 setState
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _controller.loadMore();
                  });
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(8.0),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppTheme.accentColor),
                      ),
                    ),
                  );
                }

                final video = videos[index];
                final source = ApiConfig.instance.homeSourceBean.value;

                // 索引站点 - 对应 Swift isIndexSite: 跳转搜索
                if (source != null && source.isIndexSite) {
                  return VodCard(
                    video: video,
                    onTap: () {
                      // 对应 Swift navigateToSearch(with: video.name)
                      // 使用 pendingSearchKeyword 触发搜索 overlay，匹配 Swift 行为
                      Get.find<AppState>().pendingSearchKeyword.value =
                          video.name;
                    },
                  );
                }

                // 配置中心 - 对应 Swift isConfigCenter: 打开 URL
                if (source != null && source.isConfigCenter) {
                  return VodCard(
                    video: video,
                    onTap: () => _openConfigCenterUrl(video),
                  );
                }

                // 普通源 - 对应 Swift NavigationLink
                return VodCard(
                  video: video,
                  onTap: () {
                    Get.toNamed('/detail', arguments: video);
                  },
                );
              },
            );
          },
        ),
      );
    });
  }

  /// 配置中心 URL 解析 - 对应 Swift openConfigCenterUrl
  void _openConfigCenterUrl(Video video) {
    String? openUrl;
    if (video.pic.startsWith('http')) {
      openUrl = video.pic;
      // 尝试解码 proxy URL 中的 base64 编码
      final proxyMatch = RegExp(r'/proxy/([A-Za-z0-9+/=]+)').firstMatch(video.pic);
      if (proxyMatch != null) {
        final encoded = proxyMatch.group(1);
        if (encoded != null) {
          try {
            final decoded = utf8.decode(base64Decode(encoded));
            if (decoded.startsWith('http')) {
              openUrl = decoded;
            }
          } catch (_) {}
        }
      }
    }

    if (openUrl != null) {
      // 在**应用内**打开 WebView（替代 url_launcher 跳外部浏览器），
      // 让用户保持 TVBox 上下文，符合"配置中心"的语义。
      Get.to(
        () => InAppWebViewPage(
          url: openUrl!,
          title: '配置中心',
        ),
        transition: Transition.cupertino,
      );
    }
  }
}

/// 首页时钟 - 对应 Swift HomeClockView
class _HomeClockView extends StatefulWidget {
  const _HomeClockView();

  @override
  State<_HomeClockView> createState() => _HomeClockViewState();
}

class _HomeClockViewState extends State<_HomeClockView> {
  late DateTime _now;
  late final Stream<DateTime> _stream;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _stream = Stream.periodic(
      const Duration(seconds: 1),
      (_) => DateTime.now(),
    );
  }

  String _formatDate(DateTime date) {
    final weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final weekday = weekdays[date.weekday - 1];
    final h = date.hour.toString().padLeft(2, '0');
    final m = date.minute.toString().padLeft(2, '0');
    return '${date.month}/${date.day} 周$weekday $h:$m';
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DateTime>(
      stream: _stream,
      builder: (context, snapshot) {
        final date = snapshot.data ?? _now;
        return Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.spacingMD,
            vertical: AppTheme.spacingSM,
          ),
          decoration: BoxDecoration(
            color: AppTheme.backgroundElevated,
            borderRadius: BorderRadius.circular(AppTheme.radiusMD),
            border: Border.all(
              color: AppTheme.borderLight,
              width: 0.5,
            ),
          ),
          child: Text(
            _formatDate(date),
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontFootnote,
              fontWeight: FontWeight.w500,
              fontFamily: 'monospace',
            ),
          ),
        );
      },
    );
  }
}
