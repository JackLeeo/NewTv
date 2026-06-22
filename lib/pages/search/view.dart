import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../common/theme.dart';
import '../../models/source_bean.dart';
import '../../models/movie.dart';
import '../../widgets/vod_card.dart';
import '../../widgets/common_widgets.dart';
import 'controller.dart';

/// 搜索页 - 对应 Swift SearchView
class SearchPage extends StatefulWidget {
  /// 可选的初始搜索关键词，从其他页面传入时自动搜索
  final String? initialKeyword;
  /// 关闭回调 - 对应 Swift .sheet 的 dismiss
  final VoidCallback? onClose;

  const SearchPage({super.key, this.initialKeyword, this.onClose});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  // 使用 Get.find 获取 app.dart 中注册的同一实例，避免 Get.put 创建新实例替换
  final _searchController = Get.find<TvSearchController>();
  final _inputController = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // 对应 Swift: SearchView 直接使用 viewModel.keyword
    // 从 overlay 传入时，keyword 已由 app.dart 的 ever() 回调设置
    // 这里同步 inputController 与 keyword
    if (_searchController.keyword.value.isNotEmpty) {
      _inputController.text = _searchController.keyword.value;
    } else if (widget.initialKeyword != null &&
        widget.initialKeyword!.isNotEmpty) {
      _inputController.text = widget.initialKeyword!;
      _searchController.keyword.value = widget.initialKeyword!;
      // 路由跳转方式: 设置关键词后自动触发搜索
      // overlay 方式由 app.dart 的 ever() 回调负责触发搜索
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _searchController.search();
      });
    }
  }

  @override
  void dispose() {
    _inputController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        color: AppTheme.backgroundPrimary,
        child: SafeArea(
          child: Column(
            children: [
              _buildSearchBar(),
              Expanded(
                child: Obx(() {
                  // 对应 Swift: if viewModel.activeSites.isEmpty && !viewModel.isSearching
                  if (_searchController.activeSites.isEmpty &&
                      !_searchController.isSearching.value) {
                    return _buildSearchHistorySection();
                  }
                  // 对应 Swift: GeometryReader + HStack(siteListPanel + resultsPanel)
                  return _buildSearchResultsLayout();
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // MARK: - 搜索栏

  /// 搜索栏 - 对应 Swift searchBar (含独立搜索按钮 + 渐变)
  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingSM, AppTheme.spacingXL, AppTheme.spacingXL, AppTheme.spacingMD),
      child: Row(
        children: [
          // 返回按钮 - 对应 Swift .sheet dismiss
          IconButton(
            icon: const Icon(Icons.arrow_back,
                color: AppTheme.textPrimary, size: 22),
            onPressed: () {
              if (widget.onClose != null) {
                widget.onClose!();
              } else {
                Navigator.of(context).maybePop();
              }
            },
            padding: const EdgeInsets.only(right: AppTheme.spacingSM),
            constraints: const BoxConstraints(),
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppTheme.spacingLG, vertical: AppTheme.spacingMD),
              decoration: BoxDecoration(
                color: AppTheme.backgroundSecondary,
                borderRadius: BorderRadius.circular(AppTheme.radiusLG),
              ),
              child: Row(
                children: [
                  const Icon(Icons.search,
                      color: AppTheme.textSecondary, size: 18),
                  const SizedBox(width: AppTheme.spacingSM + AppTheme.spacingXS),
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      focusNode: _focusNode,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontHeadline,
                      ),
                      decoration: const InputDecoration(
                        hintText: '搜索影片...',
                        hintStyle: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: AppTheme.fontHeadline),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onSubmitted: (value) {
                        if (value.trim().isNotEmpty) {
                          _searchController.keyword.value = value.trim();
                          _searchController.search();
                        }
                      },
                    ),
                  ),
                  // 清除按钮 - 对应 Swift xmark.circle.fill
                  Obx(() => _searchController.keyword.value.isNotEmpty
                      ? GestureDetector(
                          onTap: () {
                            _inputController.clear();
                            // 对应 Swift: 清空所有搜索状态
                            _searchController.keyword.value = '';
                            _searchController.resultsBySite.clear();
                            _searchController.searchingStatus.clear();
                            _searchController.resultCount.clear();
                            _searchController.activeSites.clear();
                            _searchController.selectedSiteKey.value = null;
                            _searchController.isSearching.value = false;
                          },
                          child: const Icon(Icons.cancel,
                              color: AppTheme.textTertiary, size: 18),
                        )
                      : const SizedBox.shrink()),
                ],
              ),
            ),
          ),
          const SizedBox(width: AppTheme.spacingMD),
          // 搜索按钮 - 对应 Swift 独立"搜索"按钮 (accentGradient)
          GestureDetector(
            onTap: () {
              final text = _inputController.text.trim();
              if (text.isNotEmpty) {
                _searchController.keyword.value = text;
                _searchController.search();
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppTheme.spacingLG, vertical: AppTheme.spacingMD),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF5CB67B), Color(0xFF7DCEA0)],
                ),
                borderRadius: BorderRadius.circular(AppTheme.radiusMD),
              ),
              child: const Text(
                '搜索',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // MARK: - 搜索结果布局

  /// 搜索结果双栏布局 - 对应 Swift GeometryReader + HStack(siteListPanel + resultsPanel)
  Widget _buildSearchResultsLayout() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 对应 Swift: min(max(geo.size.width * 0.28, 120), 220)
        final siteListWidth =
            (constraints.maxWidth * 0.28).clamp(120.0, 220.0);
        return Row(
          children: [
            SizedBox(
              width: siteListWidth,
              child: _buildSiteListPanel(),
            ),
            Container(
              width: 0.5,
              color: AppTheme.borderLight,
            ),
            Expanded(child: _buildResultsPanel()),
          ],
        );
      },
    );
  }

  // MARK: - 站点列表面板

  /// 站点列表面板 - 对应 Swift siteListPanel
  Widget _buildSiteListPanel() {
    return Container(
      color: AppTheme.backgroundSecondary,
      child: Obx(() => ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: AppTheme.spacingSM),
            itemCount: _searchController.activeSites.length,
            itemBuilder: (context, index) {
              final site = _searchController.activeSites[index];
              return _buildSiteRow(site);
            },
          )),
    );
  }

  /// 站点行 - 对应 Swift siteRow
  Widget _buildSiteRow(SourceBean site) {
    return Obx(() {
      final isSelected = _searchController.selectedSiteKey.value == site.key;
      final isSearching = _searchController.searchingStatus[site.key] ?? false;
      final count = _searchController.resultCount[site.key] ?? 0;

      return GestureDetector(
        onTap: () => _searchController.selectSite(site.key),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.spacingSM,
            vertical: AppTheme.spacingSM + AppTheme.spacingXS,
          ),
          decoration: BoxDecoration(
            color: isSelected
                ? AppTheme.accentColor.withValues(alpha: 0.1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppTheme.radiusSM),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                site.name,
                style: TextStyle(
                  color: isSelected
                      ? AppTheme.accentColor
                      : AppTheme.textSecondary,
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppTheme.spacingXS),
              Row(
                children: [
                  if (isSearching) ...[
                    const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: AppTheme.textTertiary,
                      ),
                    ),
                    const SizedBox(width: AppTheme.spacingXS),
                    const Text(
                      '搜索中...',
                      style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption,
                      ),
                    ),
                  ] else
                    Text(
                      '$count 条结果',
                      style: const TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    });
  }

  // MARK: - 结果面板

  /// 结果面板 - 对应 Swift resultsPanel
  Widget _buildResultsPanel() {
    return Obx(() {
      // 对应 Swift: selectedSiteKey == nil → "请输入搜索关键词"
      if (_searchController.selectedSiteKey.value == null) {
        return const Center(
          child: AppError(message: '请输入搜索关键词'),
        );
      }

      // 对应 Swift: isCurrentSiteSearching && currentResults.isEmpty → AppLoadingView
      if (_searchController.isCurrentSiteSearching &&
          _searchController.currentResults.isEmpty) {
        return const Center(
          child: AppLoading(message: '搜索中...'),
        );
      }

      // 对应 Swift: currentResults.isEmpty → "暂无搜索结果"
      if (_searchController.currentResults.isEmpty) {
        return const Center(
          child: AppError(message: '暂无搜索结果'),
        );
      }

      final results = _searchController.currentResults;

      // 对应 Swift: LazyVGrid(columns: adaptive)
      return LayoutBuilder(
        builder: (context, constraints) {
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
              80,
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              childAspectRatio: (cardWidth) / (cardWidth / 0.65 + 50),
              crossAxisSpacing: AppTheme.cardSpacing,
              mainAxisSpacing: AppTheme.cardSpacing,
            ),
            itemCount: results.length,
            itemBuilder: (context, index) {
              final video = results[index];
              return VodCard(
                video: video,
                onTap: () => Get.toNamed('/detail', arguments: video),
              );
            },
          );
        },
      );
    });
  }

  // MARK: - 搜索历史

  /// 搜索历史区 - 对应 Swift searchHistorySection
  Widget _buildSearchHistorySection() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppTheme.spacingXL),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_searchController.searchHistory.isNotEmpty) ...[
            Row(
              children: [
                const Text(
                  '搜索历史',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => _searchController.clearHistory(),
                  child: Row(
                    children: [
                      const Icon(Icons.delete_outline,
                          color: AppTheme.textTertiary, size: 14),
                      const SizedBox(width: AppTheme.spacingXS),
                      const Text(
                        '清空',
                        style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontCaption,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppTheme.spacingLG),
            // 对应 Swift FlowLayout / LazyVGrid
            Wrap(
              spacing: AppTheme.spacingSM,
              runSpacing: AppTheme.spacingSM,
              children: _searchController.searchHistory.map((keyword) {
                return SelectableChip(
                  title: keyword,
                  isSelected: false,
                  onTap: () {
                    _inputController.text = keyword;
                    _searchController.keyword.value = keyword;
                    _searchController.search();
                  },
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }
}
