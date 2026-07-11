import 'package:get/get.dart';
import '../../models/movie.dart';
import '../../models/cache_store.dart';
import '../../router/app_pages.dart';

/// 历史记录控制器
class HistoryController extends GetxController {
  List<VodRecord> get historyList => CacheStore.instance.records.toList();

  /// 点击历史记录 → 跳到详情页，让 detail 自己去读 playNote + VodPlaybackState 续播
  void openHistory(VodRecord item) {
    final video = Video(
      id: item.vodId,
      name: item.vodName,
      pic: item.vodPic,
      sourceKey: item.sourceKey,
    );
    Get.toNamed(AppPages.detail, arguments: video);
  }

  void deleteItem(VodRecord item) {
    CacheStore.instance.removeRecord(item.vodId, item.sourceKey);
  }

  Future<void> clearAll() async {
    await CacheStore.instance.clearHistory();
  }
}
