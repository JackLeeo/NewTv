import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../common/theme.dart';
import '../../services/api_config.dart';
import '../../services/background_service.dart';
import '../../models/source_bean.dart';
import '../../models/player_engine.dart';
import '../../widgets/common_widgets.dart';
import 'controller.dart';

/// 设置页 - 对应 Swift SettingsView
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final controller = Get.put(SettingsController());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 透明背景,让 ContentView 全局背景层透出
      backgroundColor: Colors.transparent,
      body: Container(
        color: Colors.transparent,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppTheme.spacingLG),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '设置',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontTitle3,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: AppTheme.spacingXXL),

                // 外观 - 自定义背景 (无主题切换, 始终深色)
                const SectionHeader(title: '外观'),
                const SizedBox(height: AppTheme.spacingSM),
                _buildAppearanceSection(),
                const SizedBox(height: AppTheme.spacingXXL),

                // 数据源
                const SectionHeader(title: '数据源'),
                const SizedBox(height: AppTheme.spacingSM),
                _buildDataSourceSection(),
                const SizedBox(height: AppTheme.spacingXXL),

                // 播放设置
                const SectionHeader(title: '播放设置'),
                const SizedBox(height: AppTheme.spacingSM),
                _buildPlayerSettingsSection(),
                const SizedBox(height: AppTheme.spacingXXL),

                // 缓存
                const SectionHeader(title: '缓存'),
                const SizedBox(height: AppTheme.spacingSM),
                _buildCacheSection(),
                const SizedBox(height: AppTheme.spacingXXL),

                // 关于
                const SectionHeader(title: '关于'),
                const SizedBox(height: AppTheme.spacingSM),
                _buildAboutSection(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // 外观 - 自定义背景
  // ============================================================

  Widget _buildAppearanceSection() {
    final bg = BackgroundService.instance;
    return AppCard(
      child: Obx(() => SettingsRow(
            icon: Icons.wallpaper_outlined,
            title: '应用背景',
            value: bg.choice.value == BackgroundChoice.custom
                ? '自定义图片'
                : bg.currentDisplayName,
            onTap: () => _showBackgroundPicker(bg),
          )),
    );
  }

  /// 背景选择弹窗 - 4 个内置渐变 + 相册选择 + 清除自定义
  void _showBackgroundPicker(BackgroundService bg) {
    final previews = BackgroundService.builtinPreviews;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        title: const Text('选择应用背景',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: SizedBox(
          width: 360,
          child: Obx(() => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 4 个内置渐变预览
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 0.85,
                    ),
                    itemCount: previews.length,
                    itemBuilder: (_, i) {
                      final p = previews[i];
                      final isSelected = bg.choice.value == p.choice;
                      return _BackgroundPreviewTile(
                        name: p.name,
                        colors: p.colors,
                        isSelected: isSelected,
                        onTap: () async {
                          await bg.setBuiltin(p.choice);
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  // 从相册选择
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppTheme.radiusMD),
                      onTap: () async {
                        // 关闭当前弹窗,异步选择图片
                        Navigator.pop(ctx);
                        await bg.pickFromGallery();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.backgroundTertiary,
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusMD),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.photo_library_outlined,
                                color: AppTheme.accentColor, size: 18),
                            const SizedBox(width: 10),
                            const Text(
                              '从相册选择图片',
                              style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: AppTheme.fontSubhead,
                              ),
                            ),
                            const Spacer(),
                            if (bg.choice.value == BackgroundChoice.custom)
                              const Icon(Icons.check_circle,
                                  color: AppTheme.accentColor, size: 16),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // 清除自定义
                  if (bg.choice.value == BackgroundChoice.custom) ...[
                    const SizedBox(height: 8),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusMD),
                        onTap: () async {
                          await bg.clearCustom();
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.1),
                            borderRadius:
                                BorderRadius.circular(AppTheme.radiusMD),
                            border: Border.all(
                              color: Colors.red.withValues(alpha: 0.3),
                              width: 0.5,
                            ),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.delete_outline,
                                  color: Colors.redAccent, size: 18),
                              SizedBox(width: 10),
                              Text(
                                '清除自定义图片,恢复默认',
                                style: TextStyle(
                                  color: Colors.redAccent,
                                  fontSize: AppTheme.fontSubhead,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              )),
        ),
      ),
    );
  }

  // ============================================================
  // 数据源
  // ============================================================

  Widget _buildDataSourceSection() {
    return AppCard(
      child: Column(
        children: [
          // 点播接口地址
          Obx(() => SettingsRow(
                icon: Icons.movie_outlined,
                title: '点播接口地址',
                value: controller.vodApiUrl.value.isEmpty
                    ? '未配置'
                    : _truncateUrl(controller.vodApiUrl.value),
                onTap: () => _showApiEditDialog(isVod: true),
              )),
          const Divider(color: AppTheme.borderLight, height: 1),
          // 直播接口地址
          Obx(() => SettingsRow(
                icon: Icons.tv,
                title: '直播接口地址',
                value: controller.liveApiUrl.value.isEmpty
                    ? '跟随点播接口'
                    : _truncateUrl(controller.liveApiUrl.value),
                onTap: () => _showApiEditDialog(isVod: false),
              )),
          const Divider(color: AppTheme.borderLight, height: 1),
          // 主页数据源
          Obx(() => SettingsRow(
                icon: Icons.dns_outlined,
                title: '主页数据源',
                value: ApiConfig.instance.homeSourceBean.value?.name ?? '未选择',
                onTap: () => _showSourcePicker(),
              )),
          const Divider(color: AppTheme.borderLight, height: 1),
          // 重置配置 - 回到 setupView 重新输入源 URL
          SettingsRow(
            icon: Icons.restart_alt,
            iconColor: Colors.redAccent,
            title: '重置配置',
            titleColor: Colors.redAccent,
            value: '回到初始设置',
            onTap: _showResetConfigDialog,
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 播放设置
  // ============================================================

  Widget _buildPlayerSettingsSection() {
    return AppCard(
      child: Column(
        children: [
          // 点播播放器
          Obx(() => SettingsRow(
                icon: Icons.play_circle_outline,
                title: '点播播放器',
                value: controller.vodPlayerEngine.value.title,
                onTap: () => _showEnumSelector<PlayerEngine>(
                  title: '点播播放器',
                  options: PlayerEngine.availableEngines,
                  selected: controller.vodPlayerEngine.value,
                  labelBuilder: (e) => e.title,
                  onSelect: (e) => controller.setVodPlayerEngine(e),
                ),
              )),
          const Divider(color: AppTheme.borderLight, height: 1),
          // 直播播放器
          Obx(() => SettingsRow(
                icon: Icons.radar,
                title: '直播播放器',
                value: controller.livePlayerEngine.value.title,
                onTap: () => _showEnumSelector<PlayerEngine>(
                  title: '直播播放器',
                  options: PlayerEngine.availableEngines,
                  selected: controller.livePlayerEngine.value,
                  labelBuilder: (e) => e.title,
                  onSelect: (e) => controller.setLivePlayerEngine(e),
                ),
              )),
          const Divider(color: AppTheme.borderLight, height: 1),
          // 视频解码
          Obx(() => SettingsRow(
                icon: Icons.memory,
                title: '视频解码',
                value: controller.decodeMode.value.title,
                onTap: () => _showEnumSelector<VideoDecodeMode>(
                  title: '视频解码',
                  options: VideoDecodeMode.values,
                  selected: controller.decodeMode.value,
                  labelBuilder: (e) => e.title,
                  onSelect: (e) => controller.setDecodeMode(e),
                ),
              )),
          // MPV缓冲（始终显示）
          const Divider(color: AppTheme.borderLight, height: 1),
          Obx(() => SettingsRow(
                icon: Icons.storage_outlined,
                title: 'MPV缓冲',
                value: controller.vlcBufferMode.value.title,
                onTap: () => _showEnumSelector<VLCBufferMode>(
                  title: 'MPV缓冲',
                  options: VLCBufferMode.values,
                  selected: controller.vlcBufferMode.value,
                  labelBuilder: (e) => e.title,
                  onSelect: (e) => controller.setVLCBufferMode(e),
                ),
              )),
          const Divider(color: AppTheme.borderLight, height: 1),
          // 快进步长
          Obx(() => SettingsRow(
                icon: Icons.fast_forward,
                title: '快进步长',
                value: '${controller.playTimeStep.value}秒',
                onTap: () => _showTimeStepSelector(),
              )),
        ],
      ),
    );
  }

  // ============================================================
  // 缓存
  // ============================================================

  Widget _buildCacheSection() {
    return AppCard(
      child: Obx(() => SettingsRow(
            icon: Icons.delete_outline,
            title: '清除缓存',
            value: controller.cacheSizeString.value,
            onTap: () => controller.clearCache(),
          )),
    );
  }

  // ============================================================
  // 关于
  // ============================================================

  Widget _buildAboutSection() {
    return AppCard(
      child: Column(
        children: [
          const SettingsRow(
            icon: Icons.info_outline,
            title: '版本',
            value: '1.0.0',
          ),
          const Divider(color: AppTheme.borderLight, height: 1),
          Obx(() => SettingsRow(
                icon: Icons.public,
                title: '站点数量',
                value: '${ApiConfig.instance.sourceBeanList.length}',
              )),
          const Divider(color: AppTheme.borderLight, height: 1),
          Obx(() => SettingsRow(
                icon: Icons.auto_fix_high,
                title: '解析数量',
                value: '${ApiConfig.instance.parseBeanList.length}',
              )),
          const Divider(color: AppTheme.borderLight, height: 1),
          Obx(() => SettingsRow(
                icon: Icons.live_tv_outlined,
                title: '直播分组',
                value: '${ApiConfig.instance.liveChannelGroupList.length}',
              )),
          const Divider(color: AppTheme.borderLight, height: 1),
          SettingsRow(
            icon: Icons.person_outline,
            title: '关于版本',
            value: '',
            onTap: () => _showAboutDialog(),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // API 编辑弹窗（同时支持 VOD 和 Live）
  // ============================================================

  void _showApiEditDialog({required bool isVod}) {
    final vodController = TextEditingController(text: controller.vodApiUrl.value);
    final liveController = TextEditingController(text: controller.liveApiUrl.value);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        title: Text(
          isVod ? '点播接口地址' : '直播接口地址',
          style: const TextStyle(color: AppTheme.textPrimary),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 点播接口
            TextField(
              controller: vodController,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontSubhead,
              ),
              decoration: InputDecoration(
                hintText: '输入点播接口地址',
                hintStyle: const TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontSubhead,
                ),
                filled: true,
                fillColor: AppTheme.backgroundTertiary,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusSM),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                isDense: true,
                prefixIcon: const Icon(Icons.movie_outlined,
                    size: 18, color: AppTheme.textTertiary),
              ),
            ),
            const SizedBox(height: AppTheme.spacingMD),
            // 直播接口
            TextField(
              controller: liveController,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontSubhead,
              ),
              decoration: InputDecoration(
                hintText: '输入直播接口地址（留空则跟随点播接口）',
                hintStyle: const TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontSubhead,
                ),
                filled: true,
                fillColor: AppTheme.backgroundTertiary,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusSM),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                isDense: true,
                prefixIcon: const Icon(Icons.tv,
                    size: 18, color: AppTheme.textTertiary),
              ),
            ),
            // 加载状态
            Obx(() {
              if (controller.isLoadingConfig.value) {
                return Padding(
                  padding: const EdgeInsets.only(top: AppTheme.spacingSM),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppTheme.accentColor,
                        ),
                      ),
                      const SizedBox(width: AppTheme.spacingSM),
                      const Text(
                        '正在加载配置...',
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: AppTheme.fontCaption,
                        ),
                      ),
                    ],
                  ),
                );
              }
              if (controller.configError.value != null) {
                return Padding(
                  padding: const EdgeInsets.only(top: AppTheme.spacingSM),
                  child: Text(
                    controller.configError.value!,
                    style: const TextStyle(
                        color: Colors.red, fontSize: AppTheme.fontCaption),
                  ),
                );
              }
              if (controller.configSuccess.value) {
                return Padding(
                  padding: const EdgeInsets.only(top: AppTheme.spacingSM),
                  child: const Text(
                    '配置加载成功',
                    style: TextStyle(
                        color: AppTheme.accentColor,
                        fontSize: AppTheme.fontCaption),
                  ),
                );
              }
              return const SizedBox.shrink();
            }),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消',
                style: TextStyle(color: AppTheme.textTertiary)),
          ),
          Obx(() => TextButton(
                onPressed: controller.isLoadingConfig.value
                    ? null
                    : () {
                        controller.vodApiUrl.value =
                            vodController.text.trim();
                        controller.liveApiUrl.value =
                            liveController.text.trim();
                        controller.loadConfig();
                      },
                child: const Text('加载',
                    style: TextStyle(color: AppTheme.accentColor)),
              )),
        ],
      ),
    );
  }

  // ============================================================
  // 主页数据源选择
  // ============================================================

  void _showSourcePicker() {
    final sources = ApiConfig.instance.sourceBeanList;
    if (sources.isEmpty) {
      _showApiEditDialog(isVod: true);
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        title: const Text('主页数据源',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Obx(() {
          final homeKey = ApiConfig.instance.homeSourceBean.value?.key;
          return ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 400),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: sources.length,
              itemBuilder: (context, index) {
                final source = sources[index];
                final isHome = homeKey == source.key;
                return Material(
                  color: Colors.transparent,
                  child: ListTile(
                    dense: true,
                    title: Text(
                      source.name,
                      style: TextStyle(
                        color: isHome
                            ? AppTheme.accentColor
                            : AppTheme.textPrimary,
                        fontWeight:
                            isHome ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                    subtitle: Text(
                      source.api,
                      style: const TextStyle(
                          color: AppTheme.textTertiary, fontSize: 10),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: isHome
                        ? const Icon(Icons.check_circle,
                            color: AppTheme.accentColor, size: 16)
                        : null,
                    onTap: () {
                      ApiConfig.instance.setHomeSource(source);
                      Navigator.pop(ctx);
                    },
                  ),
                );
              },
            ),
          );
        }),
      ),
    );
  }

  // ============================================================
  // 通用枚举选择器
  // ============================================================

  void _showEnumSelector<T>({
    required String title,
    required List<T> options,
    required T selected,
    required String Function(T) labelBuilder,
    required ValueChanged<T> onSelect,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        title:
            Text(title, style: const TextStyle(color: AppTheme.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: options.map((option) {
            final isSelected = option == selected;
            return Material(
              color: Colors.transparent,
              child: ListTile(
                dense: true,
                title: Text(labelBuilder(option),
                    style: TextStyle(
                      color: isSelected
                          ? AppTheme.accentColor
                          : AppTheme.textPrimary,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.normal,
                    )),
                trailing: isSelected
                    ? const Icon(Icons.check_circle,
                        color: AppTheme.accentColor, size: 18)
                    : null,
                onTap: () {
                  onSelect(option);
                  Navigator.pop(ctx);
                },
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  // ============================================================
  // 快进步长选择器
  // ============================================================

  void _showTimeStepSelector() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        title: const Text('快进步长',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: controller.playTimeStepOptions.map((step) {
            final isSelected = controller.playTimeStep.value == step;
            return Material(
              color: Colors.transparent,
              child: ListTile(
                dense: true,
                title: Text('$step秒',
                    style: TextStyle(
                      color: isSelected
                          ? AppTheme.accentColor
                          : AppTheme.textPrimary,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.normal,
                    )),
                trailing: isSelected
                    ? const Icon(Icons.check_circle,
                        color: AppTheme.accentColor, size: 18)
                    : null,
                onTap: () {
                  controller.setPlayTimeStep(step);
                  Navigator.pop(ctx);
                },
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  // ============================================================
  // 重置配置对话框 - 清掉已保存的源 URL，重启后回到 setupView
  // ============================================================

  void _showResetConfigDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        title: const Row(
          children: [
            Icon(Icons.restart_alt, color: Colors.redAccent, size: 22),
            SizedBox(width: 8),
            Text(
              '重置配置',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontTitle3,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: const Text(
          '将清除已保存的点播/直播接口地址、接口历史以及已下载的源缓存。\n\n'
          '播放器、主题、字体等本地设置会保留。\n\n'
          '重置后请重启应用，下次打开将回到初始设置界面。',
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: AppTheme.fontSubhead,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消',
                style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await controller.resetConfig();
              if (!mounted) return;
              await showDialog(
                context: context,
                builder: (ctx2) => AlertDialog(
                  backgroundColor: AppTheme.backgroundSecondary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusLG),
                  ),
                  content: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle,
                          color: AppTheme.accentColor, size: 48),
                      SizedBox(height: 12),
                      Text(
                        '配置已重置',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontTitle3,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        '请退出应用后重新打开，\n将进入初始设置界面。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: AppTheme.fontSubhead,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx2),
                      child: const Text('知道了',
                          style: TextStyle(color: AppTheme.accentColor)),
                    ),
                  ],
                ),
              );
            },
            child: const Text('重置',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 关于版本弹窗
  // ============================================================

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.play_circle_filled,
                color: AppTheme.accentColor, size: 48),
            const SizedBox(height: AppTheme.spacingLG),
            const Text(
              'TVBox',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontTitle3,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: AppTheme.spacingXS),
            const Text(
              '版本 1.0.0',
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
              ),
            ),
            const SizedBox(height: AppTheme.spacingXS),
            const Text(
              '软件作者：包子',
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('确定',
                style: TextStyle(color: AppTheme.accentColor)),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 工具方法
  // ============================================================

  String _truncateUrl(String url) {
    if (url.length > 30) {
      return '${url.substring(0, 27)}...';
    }
    return url;
  }
}

/// 背景预览小方块 - 4 个内置渐变缩略图
class _BackgroundPreviewTile extends StatelessWidget {
  final String name;
  final List<Color> colors;
  final bool isSelected;
  final VoidCallback onTap;

  const _BackgroundPreviewTile({
    required this.name,
    required this.colors,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: colors,
                ),
                borderRadius: BorderRadius.circular(AppTheme.radiusMD),
                border: Border.all(
                  color: isSelected
                      ? AppTheme.accentColor
                      : AppTheme.borderLight,
                  width: isSelected ? 2 : 0.5,
                ),
              ),
              child: isSelected
                  ? const Center(
                      child: Icon(
                        Icons.check_circle,
                        color: Colors.white,
                        size: 22,
                        shadows: [
                          Shadow(blurRadius: 4, color: Colors.black54),
                        ],
                      ),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            name,
            style: TextStyle(
              color: isSelected ? AppTheme.accentColor : AppTheme.textSecondary,
              fontSize: AppTheme.fontCaption,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
