import 'package:flutter/material.dart';
import '../../common/theme.dart';

/// 剧集列表组件 - 对应 Swift EpisodeListView
/// 分组展示剧集（每组50个），网格布局
class EpisodeListView extends StatelessWidget {
  final List<String> episodeNames;
  final int selectedIndex;
  final ValueChanged<int> onEpisodeTap;

  const EpisodeListView({
    super.key,
    required this.episodeNames,
    required this.selectedIndex,
    required this.onEpisodeTap,
  });

  static const int _groupSize = 50;

  List<List<String>> get _groups {
    final groups = <List<String>>[];
    for (var i = 0; i < episodeNames.length; i += _groupSize) {
      final end = (i + _groupSize).clamp(0, episodeNames.length);
      groups.add(episodeNames.sublist(i, end));
    }
    return groups;
  }

  String _groupTitle(int groupIndex, int groupLength) {
    final start = groupIndex * _groupSize + 1;
    final end = start + groupLength - 1;
    return '$start-$end';
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    if (groups.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var g = 0; g < groups.length; g++) ...[
          Padding(
            padding: const EdgeInsets.only(
              top: AppTheme.spacingSM,
              bottom: AppTheme.spacingSM,
            ),
            child: Text(
              _groupTitle(g, groups[g].length),
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontSubhead,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Wrap(
            spacing: AppTheme.spacingSM,
            runSpacing: AppTheme.spacingSM,
            children: [
              for (var i = 0; i < groups[g].length; i++)
                _buildEpisodeChip(
                  globalIndex: g * _groupSize + i,
                  name: groups[g][i],
                  isSelected: g * _groupSize + i == selectedIndex,
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildEpisodeChip({
    required int globalIndex,
    required String name,
    required bool isSelected,
  }) {
    return GestureDetector(
      onTap: () => onEpisodeTap(globalIndex),
      child: Container(
        constraints: const BoxConstraints(minWidth: 60, maxWidth: 120),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.accentColor.withValues(alpha: 0.15)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(AppTheme.radiusSM),
          border: isSelected
              ? Border.all(color: AppTheme.accentColor.withValues(alpha: 0.4))
              : null,
        ),
        child: Text(
          name,
          style: TextStyle(
            color: isSelected ? AppTheme.accentColor : AppTheme.textSecondary,
            fontSize: AppTheme.fontSubhead,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          ),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
