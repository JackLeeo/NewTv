import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../common/theme.dart';
import '../../widgets/vod_card.dart';
import '../../widgets/common_widgets.dart';
import '../../models/cache_store.dart';
import '../../models/movie.dart';
import 'controller.dart';

/// 历史页 - 对应 Swift HistoryView
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.put(HistoryController());

    return Scaffold(
      // 透明背景,让 ContentView 全局背景层透出
      backgroundColor: Colors.transparent,
      body: Container(
        color: Colors.transparent,
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

  Widget _buildHeader(HistoryController controller) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingXL, AppTheme.spacingLG, AppTheme.spacingXL, AppTheme.spacingSM),
      child: Row(
        children: [
          const Text(
            '历史记录',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontTitle3,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          Obx(() {
            if (CacheStore.instance.records.isEmpty) return const SizedBox.shrink();
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

  Widget _buildContent(HistoryController controller) {
    return Obx(() {
      final records = CacheStore.instance.records;
      if (records.isEmpty) {
        return const EmptyState(
          title: '暂无历史记录',
          message: '观看影片后会自动记录',
          icon: Icons.history,
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
        itemCount: records.length,
        itemBuilder: (context, index) {
          final item = records[index];
          final video = Video(
            id: item.vodId,
            name: item.vodName,
            pic: item.vodPic,
            sourceKey: item.sourceKey,
          );
          return GestureDetector(
            onSecondaryTap: () =>
                _showDeleteConfirmDialog(context, controller, item),
            onLongPress: () =>
                _showDeleteConfirmDialog(context, controller, item),
            child: VodCard(
              video: video,
              onTap: () => Get.toNamed('/detail', arguments: video),
            ),
          );
        },
      );
    });
  }

  void _showDeleteConfirmDialog(
    BuildContext context,
    HistoryController controller,
    VodRecord item,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusLG)),
        title: const Text('删除记录',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('确定删除「${item.vodName}」的观看记录？',
            style: const TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消',
                style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () {
              controller.deleteItem(item);
              Navigator.pop(context);
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showClearConfirmDialog(
    BuildContext context,
    HistoryController controller,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusLG)),
        title: const Text('清空历史',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text('确定清空所有观看记录？此操作不可恢复。',
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
