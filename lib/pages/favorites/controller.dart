import 'package:get/get.dart';
import '../../models/movie.dart';
import '../../models/cache_store.dart';

/// 收藏控制器
class FavoritesController extends GetxController {
  List<VodCollect> get favoritesList => CacheStore.instance.favorites.toList();

  Future<void> removeItem(VodCollect item) async {
    await CacheStore.instance.removeCollect(item.vodId, item.sourceKey);
  }

  Future<void> clearAll() async {
    // 清空所有收藏
    final items = CacheStore.instance.favorites.toList();
    for (final item in items) {
      await CacheStore.instance.removeCollect(item.vodId, item.sourceKey);
    }
  }
}
