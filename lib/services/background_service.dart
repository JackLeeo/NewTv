import 'dart:io';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

/// 背景选择类型
enum BackgroundChoice {
  /// 4 个内置渐变(1-4)
  builtin1,
  builtin2,
  builtin3,
  builtin4,

  /// 用户上传的自定义图片
  custom,
}

/// 全局背景服务 - 对应 TV-release CustomWallView
///
/// 4 个内置渐变(深邃黑/极光紫/赛博蓝/暖阳橙) + 用户上传自定义图片
/// 跟随全应用统一背景渲染（深色主题）
class BackgroundService extends GetxService {
  static BackgroundService get instance => Get.find<BackgroundService>();

  static const String _choiceKey = 'background_choice';
  static const String _customPathKey = 'background_custom_path';

  final ImagePicker _picker = ImagePicker();

  /// 当前背景选择
  final choice = BackgroundChoice.builtin1.obs;

  /// 自定义背景图片路径(仅 choice == custom 时有效)
  final customPath = RxnString();

  /// 启动时调用 - 从 SharedPreferences 加载
  @override
  void onInit() {
    super.onInit();
    _loadFromPrefs();
  }

  /// 异步加载 SharedPreferences 中的背景选择 + 自定义图片路径
  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_choiceKey);
    if (saved != null) {
      choice.value = BackgroundChoice.values.firstWhere(
        (e) => e.name == saved,
        orElse: () => BackgroundChoice.builtin1,
      );
    }
    customPath.value = prefs.getString(_customPathKey);
    print('[BackgroundService] 已加载: choice=${choice.value}, '
        'customPath=${customPath.value}');
  }

  /// 设置内置背景
  Future<void> setBuiltin(BackgroundChoice c) async {
    choice.value = c;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_choiceKey, c.name);
    print('[BackgroundService] setBuiltin: $c');
  }

  /// 设置自定义背景 - 复制到应用文档目录并保存路径
  Future<bool> setCustomImage(String sourcePath) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final wallDir = Directory('${docs.path}/wallpaper');
      if (!wallDir.existsSync()) wallDir.createSync(recursive: true);
      final ext = sourcePath.contains('.')
          ? sourcePath.substring(sourcePath.lastIndexOf('.'))
          : '.jpg';
      final destPath =
          '${wallDir.path}/bg_${DateTime.now().millisecondsSinceEpoch}$ext';
      await File(sourcePath).copy(destPath);

      // 删除旧的自定义背景
      final oldPath = customPath.value;
      if (oldPath != null && oldPath != destPath) {
        try {
          final f = File(oldPath);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }

      customPath.value = destPath;
      choice.value = BackgroundChoice.custom;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_choiceKey, BackgroundChoice.custom.name);
      await prefs.setString(_customPathKey, destPath);
      print('[BackgroundService] setCustomImage: $destPath');
      return true;
    } catch (e) {
      print('[BackgroundService] setCustomImage 失败: $e');
      return false;
    }
  }

  /// 清除自定义背景 - 回到默认(builtin1)
  Future<void> clearCustom() async {
    final oldPath = customPath.value;
    if (oldPath != null) {
      try {
        final f = File(oldPath);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    customPath.value = null;
    await setBuiltin(BackgroundChoice.builtin1);
  }

  /// 弹出图片选择器 - 选完图后自动 setCustomImage
  Future<bool> pickFromGallery() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 4096,
        maxHeight: 4096,
        imageQuality: 92,
      );
      if (picked == null) return false;
      return await setCustomImage(picked.path);
    } catch (e) {
      print('[BackgroundService] pickFromGallery 失败: $e');
      return false;
    }
  }

  // ============================================================
  // 4 个内置渐变定义 (深色系)
  // ============================================================

  /// 深邃黑
  static const List<Color> _builtin1 = [
    Color(0xFF0A0A0F),
    Color(0xFF14141C),
    Color(0xFF0A0A0F),
  ];

  /// 极光紫
  static const List<Color> _builtin2 = [
    Color(0xFF1A0A2E),
    Color(0xFF4A1B6B),
    Color(0xFF7B2C8C),
  ];

  /// 赛博蓝
  static const List<Color> _builtin3 = [
    Color(0xFF0A1230),
    Color(0xFF1E3A8A),
    Color(0xFF2563EB),
  ];

  /// 暖阳橙
  static const List<Color> _builtin4 = [
    Color(0xFF2A0E0A),
    Color(0xFF7C2D12),
    Color(0xFFEA580C),
  ];

  List<Color> _getGradientForChoice(BackgroundChoice c) {
    switch (c) {
      case BackgroundChoice.builtin1:
        return _builtin1;
      case BackgroundChoice.builtin2:
        return _builtin2;
      case BackgroundChoice.builtin3:
        return _builtin3;
      case BackgroundChoice.builtin4:
        return _builtin4;
      case BackgroundChoice.custom:
        return _builtin1;
    }
  }

  /// 构建背景 widget - 对应 TV-release CustomWallView
  ///
  /// [overlayAlpha]: 上层蒙版 alpha (0-1, 越大越暗, 用于保证文字可读)
  Widget buildBackground({
    double overlayAlpha = 0.3,
    Widget? child,
  }) {
    return Obx(() {
      // 自定义图片模式
      if (choice.value == BackgroundChoice.custom &&
          customPath.value != null) {
        final file = File(customPath.value!);
        if (file.existsSync()) {
          return Stack(
            fit: StackFit.expand,
            children: [
              Image.file(
                file,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildGradientFallback(
                    overlayAlpha: overlayAlpha),
              ),
              if (overlayAlpha > 0)
                Container(color: Colors.black.withValues(alpha: overlayAlpha)),
              if (child != null) child,
            ],
          );
        }
      }

      // 内置渐变模式
      return _buildGradientBackground(
        colors: _getGradientForChoice(choice.value),
        overlayAlpha: overlayAlpha,
        child: child,
      );
    });
  }

  Widget _buildGradientBackground({
    required List<Color> colors,
    double overlayAlpha = 0.3,
    Widget? child,
  }) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 主渐变
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: colors,
            ),
          ),
        ),
        // 装饰圆形
        Positioned(
          top: -120,
          right: -80,
          child: _buildCircle(
            size: 420,
            color: Colors.white.withValues(alpha: 0.04),
          ),
        ),
        Positioned(
          bottom: -160,
          left: -100,
          child: _buildCircle(
            size: 520,
            color: Colors.white.withValues(alpha: 0.03),
          ),
        ),
        Positioned(
          top: 200,
          right: -60,
          child: _buildCircle(
            size: 220,
            color: Colors.white.withValues(alpha: 0.05),
          ),
        ),
        // 蒙版 (保证文字可读)
        if (overlayAlpha > 0)
          Container(color: Colors.black.withValues(alpha: overlayAlpha)),
        if (child != null) child,
      ],
    );
  }

  Widget _buildGradientFallback({required double overlayAlpha}) {
    return _buildGradientBackground(
      colors: _getGradientForChoice(BackgroundChoice.builtin1),
      overlayAlpha: overlayAlpha,
    );
  }

  Widget _buildCircle({required double size, required Color color}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
      ),
    );
  }

  /// 当前选择的内置背景名 (用于设置页展示)
  String get currentDisplayName {
    switch (choice.value) {
      case BackgroundChoice.builtin1:
        return '深邃黑';
      case BackgroundChoice.builtin2:
        return '极光紫';
      case BackgroundChoice.builtin3:
        return '赛博蓝';
      case BackgroundChoice.builtin4:
        return '暖阳橙';
      case BackgroundChoice.custom:
        return '自定义图片';
    }
  }

  /// 获取所有内置背景的 preview 色 (用于设置页的预览小方块)
  static List<({String name, BackgroundChoice choice, List<Color> colors})>
      get builtinPreviews {
    return [
      (
        name: '深邃黑',
        choice: BackgroundChoice.builtin1,
        colors: _builtin1,
      ),
      (
        name: '极光紫',
        choice: BackgroundChoice.builtin2,
        colors: _builtin2,
      ),
      (
        name: '赛博蓝',
        choice: BackgroundChoice.builtin3,
        colors: _builtin3,
      ),
      (
        name: '暖阳橙',
        choice: BackgroundChoice.builtin4,
        colors: _builtin4,
      ),
    ];
  }
}
