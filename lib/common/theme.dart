import 'package:flutter/material.dart';

/// 主题配置 - 匹配 tvbox-Swift 设计系统
class AppTheme {
  // 颜色
  static const Color accentColor = Color(0xFF5CB67B);
  static const Color accentLightColor = Color(0xFF7DCEA0);
  static const Color backgroundPrimary = Color(0xFF0F0F0F);
  static const Color backgroundSecondary = Color(0xFF1A1A1A);
  static const Color backgroundTertiary = Color(0x0FFFFFFF); // white 6%
  static const Color backgroundElevated = Color(0x14FFFFFF); // white 8%

  // ===== 半透明卡片色 =====
  // 专为主 tab 视图内的卡片/容器设计, 让 BackgroundService 全局背景层透出
  // 替换原 backgroundSecondary (完全不透明) 造成的"黑色板块"问题
  //
  // backgroundCard: 80% 透明度的 #1A1A1A, 适合 AppCard / VodCard
  // backgroundCardElevated: 90% 透明度, 适合高亮/选中状态容器
  // backgroundNavBar: 80% 透明度的 #1C1C1E, 适合底部导航栏
  // 0xCC = 204/255 ≈ 80%, 0xE6 = 230/255 ≈ 90%
  static const Color backgroundCard = Color(0xCC1A1A1A);
  static const Color backgroundCardElevated = Color(0xE61A1A1A);
  static const Color backgroundNavBar = Color(0xCC1C1C1E);

  static const Color textPrimary = Color(0xEBEBEBEB); // white 92%
  static const Color textSecondary = Color(0x8CFFFFFF); // white 55%
  static const Color textTertiary = Color(0x59FFFFFF); // white 35%

  static const Color borderLight = Color(0x14FFFFFF); // white 8%
  static const Color borderMedium = Color(0x24FFFFFF); // white 14%

  // 间距
  static const double spacingXS = 4;
  static const double spacingSM = 8;
  static const double spacingMD = 12;
  static const double spacingLG = 16;
  static const double spacingXL = 20;
  static const double spacingXXL = 24;

  // 圆角
  static const double radiusSM = 8;
  static const double radiusMD = 10;
  static const double radiusLG = 14;
  static const double radiusXL = 20;

  // 卡片
  static const double cardRadius = 10;
  static const double cardSpacing = 6;
  static const double cardPadding = 8;

  // 字号
  static const double fontCaption = 11;
  static const double fontFootnote = 12;
  static const double fontSubhead = 13;
  static const double fontBody = 14;
  static const double fontHeadline = 16;
  static const double fontTitle3 = 18;
  static const double fontTitle2 = 20;

  /// 暗色主题
  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: backgroundPrimary,
      colorScheme: const ColorScheme.dark(
        primary: accentColor,
        secondary: accentLightColor,
        surface: backgroundSecondary,
        error: Colors.red,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: backgroundPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: fontHeadline,
          fontWeight: FontWeight.bold,
        ),
        iconTheme: IconThemeData(color: textSecondary),
      ),
      cardTheme: CardThemeData(
        color: backgroundSecondary,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: backgroundTertiary,
        selectedColor: accentColor.withValues(alpha: 0.15),
        labelStyle: const TextStyle(color: textSecondary, fontSize: fontSubhead),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Color(0xFF1C1C1E),
        selectedItemColor: accentColor,
        unselectedItemColor: textTertiary,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: TextStyle(fontSize: 10, fontWeight: FontWeight.w500),
        unselectedLabelStyle: TextStyle(fontSize: 10),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: backgroundSecondary,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMD),
          borderSide: BorderSide.none,
        ),
        hintStyle: const TextStyle(color: textTertiary, fontSize: fontSubhead),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: spacingLG,
          vertical: spacingMD,
        ),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
            color: textPrimary, fontSize: 48, fontWeight: FontWeight.w800),
        headlineMedium: TextStyle(
            color: textPrimary, fontSize: fontTitle2, fontWeight: FontWeight.w700),
        headlineSmall: TextStyle(
            color: textPrimary, fontSize: fontTitle3, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(color: textPrimary, fontSize: fontBody),
        bodyMedium: TextStyle(color: textSecondary, fontSize: fontSubhead),
        bodySmall: TextStyle(color: textTertiary, fontSize: fontFootnote),
        labelLarge: TextStyle(
            color: textPrimary, fontSize: fontBody, fontWeight: FontWeight.w600),
        labelMedium: TextStyle(color: textSecondary, fontSize: fontSubhead),
        labelSmall: TextStyle(color: textTertiary, fontSize: fontCaption),
      ),
      useMaterial3: true,
    );
  }
}
