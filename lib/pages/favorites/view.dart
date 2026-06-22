import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../common/theme.dart';
import '../../widgets/vod_card.dart';
import '../../widgets/common_widgets.dart';
import '../../models/cache_store.dart';
import '../../models/movie.dart';
import 'controller.dart';

/// 收藏页 - 对应 Swift FavoritesView
class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.put(FavoritesController());

    return Scaffold(
      body: Container(
        color: AppTheme.backgroundPrimary,
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(controller),
              Expanded(child: _buildContent(controller)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(FavoritesController controller) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingXL, AppTheme.spacingLG, AppTheme.spacingXL, AppTheme.spacingSM),
      child: Row(
        children: [
          const Text(
            '我的收藏',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontTitle3,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          Obx(() {
            if (CacheStore.instance.favorites.isEmpty) {
              return const SizedBox.shrink();
            }
            return TextButton(
              onPressed: () => _showClearConfirmDialog(Get.context!, controller),
              child: const Text(
                '清空',
                style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontCaption),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildContent(FavoritesController controller) {
    return Obx(() {
      final favorites = CacheStore.instance.favorites;
      if (favorites.isEmpty) {
        return const EmptyState(
          title: '暂无收藏',
          message: '收藏影片后会显示在这里',
          icon: Icons.favorite_border,
        );
      }

      return GridView.builder(
        padding: const EdgeInsets.all(AppTheme.spacingLG),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          childAspectRatio: 0.65,
          crossAxisSpacing: AppTheme.cardSpacing,
          mainAxisSpacing: AppTheme.cardSpacing,
        ),
        itemCount: favorites.length,
        itemBuilder: (context, index) {
          final item = favorites[index];
          final video = Video(
            id: item.vodId,
            name: item.vodName,
            pic: item.vodPic,
            sourceKey: item.sourceKey,
          );
          return GestureDetector(
            onSecondaryTap: () =>
                _showUnfavoriteDialog(context, controller, item),
            onLongPress: () =>
                _showUnfavoriteDialog(context, controller, item),
            child: VodCard(
              video: video,
              onTap: () => Get.toNamed('/detail', arguments: video),
            ),
          );
        },
      );
    });
  }

  void _showUnfavoriteDialog(
    BuildContext context,
    FavoritesController controller,
    VodCollect item,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusLG)),
        title: const Text('取消收藏',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('确定取消收藏「${item.vodName}」？',
            style: const TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消',
                style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () {
              controller.removeItem(item);
              Navigator.pop(context);
            },
            child: const Text('取消收藏', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showClearConfirmDialog(
    BuildContext context,
    FavoritesController controller,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusLG)),
        title: const Text('清空收藏',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text('确定清空所有收藏？此操作不可恢复。',
            style: TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消',
                style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () {
              controller.clearAll();
              Navigator.pop(context);
            },
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
