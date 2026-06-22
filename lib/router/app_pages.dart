import 'package:get/get.dart';
import '../pages/home/view.dart';
import '../pages/live/view.dart';
import '../pages/history/view.dart';
import '../pages/favorites/view.dart';
import '../pages/settings/view.dart';
import '../pages/detail/view.dart';
import '../pages/search/view.dart';
import '../pages/dlna/view.dart';

class AppPages {
  static const String detail = '/detail';
  static const String search = '/search';
  static const String dlna = '/dlna';

  static final pages = [
    GetPage(
      name: detail,
      page: () => DetailPage(),
    ),
    GetPage(
      name: search,
      page: () => SearchPage(
        // 对应 Swift: 从其他页面传入关键词时自动搜索
        initialKeyword: Get.arguments as String?,
      ),
    ),
    GetPage(
      name: dlna,
      page: () => const DLNAPage(),
    ),
  ];
}
