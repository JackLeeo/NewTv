import 'package:flutter/material.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:get/get.dart';
import '../../common/theme.dart';
import '../../widgets/common_widgets.dart';
import '../../models/cache_store.dart';
import 'controller.dart';

/// 历史页 - 对应 Swift HistoryView
///
/// **2026-07-09 重构**: 从 GridView 卡片列表改为 ListView 详情列表
///
/// 原版用 VodCard 网格 (crossAxisCount: 4, aspectRatio: 0.65), 每个卡片
/// 只显示海报+名称, 用户反馈看不到"最后播放时间/集数/进度/标题". 改成
/// ListView 每项包含:
///   - 左侧封面 (16:9 缩略图, 失败时降级到带 URL 的占位图)
///   - 右侧标题 (vodName) + 集数 (playNote) + 进度 (mm:ss / mm:ss)
///   - 底部时间 (今天 HH:mm / 昨天 HH:mm / YYYY-MM-DD)
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

      return ListView.separated(
        padding: const EdgeInsets.fromLTRB(
            AppTheme.spacingLG, 0, AppTheme.spacingLG, AppTheme.spacingLG),
        itemCount: records.length,
        separatorBuilder: (_, __) => const SizedBox(height: AppTheme.spacingSM),
        itemBuilder: (context, index) {
          final item = records[index];
          return _HistoryListItem(
            record: item,
            onTap: () {
              // 跳转到详情页, 让 detail 自己去读 playNote + VodPlaybackState 续播
              controller.openHistory(item);
            },
            onLongPress: () =>
                _showDeleteConfirmDialog(context, controller, item),
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

/// 单条历史记录 - 列表行
/// - 左侧 16:9 缩略图 (try 网络图, 失败降级到带 URL 的占位)
/// - 右侧 标题 + 集数 + 进度 (mm:ss / mm:ss)
/// - 底部 时间 (今天 / 昨天 / YYYY-MM-DD)
class _HistoryListItem extends StatelessWidget {
  final VodRecord record;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _HistoryListItem({
    required this.record,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.all(AppTheme.spacingMD),
        decoration: BoxDecoration(
          color: AppTheme.backgroundCard,
          borderRadius: BorderRadius.circular(AppTheme.radiusMD),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 左侧封面
            _buildCover(),
            const SizedBox(width: AppTheme.spacingMD),
            // 右侧详情
            Expanded(child: _buildInfo()),
          ],
        ),
      ),
    );
  }

  /// 16:9 缩略图 - 失败降级到带 URL 的占位 (而不是空白)
  Widget _buildCover() {
    final rawUrl = record.vodPic.trim();
    final url = _normalizeUrl(rawUrl);
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTheme.radiusSM),
      child: SizedBox(
        width: 140,
        height: 80, // 140/80 ≈ 16:9
        child: url.isEmpty
            ? _buildCoverPlaceholder()
            : CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                httpHeaders: {
                  'User-Agent': 'Mozilla/5.0',
                  'Referer': 'https://${Uri.parse(url).host}/',
                },
                placeholder: (context, _) => _buildCoverPlaceholder(loading: true),
                errorBuilder: (context, _, __) => _buildCoverPlaceholder(),
              ),
      ),
    );
  }

  Widget _buildCoverPlaceholder({bool loading = false}) {
    return Container(
      color: AppTheme.backgroundTertiary,
      child: Center(
        child: loading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppTheme.accentColor,
                ),
              )
            : const Icon(Icons.movie,
                color: AppTheme.textTertiary, size: 24),
      ),
    );
  }

  /// 右侧详情 - 标题 + 集数 + 进度 + 时间
  Widget _buildInfo() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 标题 (最多 2 行)
        Text(
          record.vodName,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontBody,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        // 集数 (playNote = "线路 - 集名" e.g. "1080P - 第1集")
        if (record.playNote.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              record.playNote,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontFootnote,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        // 进度 (mm:ss / mm:ss)
        if (_hasProgress) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              const Icon(Icons.play_circle_outline,
                  color: AppTheme.accentColor, size: 12),
              const SizedBox(width: 4),
              Text(
                _progressText,
                style: const TextStyle(
                  color: AppTheme.accentColor,
                  fontSize: AppTheme.fontCaption,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 6),
        // 底部时间
        Row(
          children: [
            const Icon(Icons.schedule,
                color: AppTheme.textTertiary, size: 11),
            const SizedBox(width: 4),
            Text(
              _formatUpdateTime(record.updateTime),
              style: const TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
              ),
            ),
          ],
        ),
      ],
    );
  }

  bool get _hasProgress {
    if (record.dataJson.isEmpty) return false;
    final state = CacheStore.instance.getPlaybackState(record.vodId, record.sourceKey);
    if (state == null) return false;
    return state.progressSeconds > 0;
  }

  String get _progressText {
    final state =
        CacheStore.instance.getPlaybackState(record.vodId, record.sourceKey);
    if (state == null) return '';
    final current = _formatDuration(state.progressSeconds);
    return '已观看 $current';
  }

  static String _formatDuration(double seconds) {
    final total = seconds.toInt();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// 时间格式: 今天 HH:mm / 昨天 HH:mm / MM-DD HH:mm / YYYY-MM-DD HH:mm
  static String _formatUpdateTime(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final recordDay = DateTime(t.year, t.month, t.day);
    final diffDays = today.difference(recordDay).inDays;
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    if (diffDays == 0) {
      return '今天 $hh:$mm';
    }
    if (diffDays == 1) {
      return '昨天 $hh:$mm';
    }
    if (t.year == now.year) {
      return '${_pad2(t.month)}-${_pad2(t.day)} $hh:$mm';
    }
    return '${t.year}-${_pad2(t.month)}-${_pad2(t.day)} $hh:$mm';
  }

  static String _pad2(int v) => v.toString().padLeft(2, '0');

  /// 把 //xxx 这种 protocol-relative URL 补成 https://
  /// 其他 (http://, https://, 空) 保持不变
  static String _normalizeUrl(String url) {
    if (url.isEmpty) return '';
    if (url.startsWith('//')) return 'https:$url';
    return url;
  }
}
