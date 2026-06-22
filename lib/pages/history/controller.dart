import 'package:get/get.dart';
import '../../models/movie.dart';
import '../../models/cache_store.dart';

/// 历史记录控制器
class HistoryController extends GetxController {
  List<VodRecord> get historyList => CacheStore.instance.records.toList();

  void deleteItem(VodRecord item) {
    CacheStore.instance.removeRecord(item.vodId, item.sourceKey);
  }

  Future<void> clearAll() async {
    await CacheStore.instance.clearHistory();
  }
}
