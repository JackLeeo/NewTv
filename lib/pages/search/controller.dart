import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/movie.dart';
import '../../models/source_bean.dart';
import '../../services/api_config.dart';
import '../../services/source_service.dart';
import '../../common/constants.dart';

class TvSearchController extends GetxController {
  final keyword = ''.obs;
  final searchHistory = <String>[].obs;
  final resultsBySite = <String, List<Video>>{}.obs;
  final searchingStatus = <String, bool>{}.obs;
  final resultCount = <String, int>{}.obs;
  final activeSites = <SourceBean>[].obs;
  final selectedSiteKey = Rx<String?>(null);
  final isSearching = false.obs;

  String _latestSearchRequestId = '';

  @override
  void onInit() {
    super.onInit();
    loadSearchHistory();
  }

  List<Video> get currentResults {
    final key = selectedSiteKey.value;
    if (key == null) return [];
    return resultsBySite[key] ?? [];
  }

  bool get isCurrentSiteSearching {
    final key = selectedSiteKey.value;
    if (key == null) return false;
    return searchingStatus[key] ?? false;
  }

  Future<void> search() async {
    final trimmed = keyword.value.trim();
    if (trimmed.isEmpty) return;

    final requestId = '${DateTime.now().microsecondsSinceEpoch}';
    _latestSearchRequestId = requestId;

    addToHistory(trimmed);

    final sources = ApiConfig.instance.getSearchableSources();
    final validSources = sources
        .where((s) =>
            s.isSupportedInSwift && s.key != 'douban' && s.key != 'baseset')
        .toList();

    isSearching.value = true;
    resultsBySite.clear();
    searchingStatus.clear();
    resultCount.clear();
    activeSites.value = validSources;

    if (selectedSiteKey.value == null ||
        !validSources.any((s) => s.key == selectedSiteKey.value)) {
      selectedSiteKey.value =
          validSources.isNotEmpty ? validSources.first.key : null;
    }

    for (final source in validSources) {
      searchingStatus[source.key] = true;
      resultCount[source.key] = 0;
    }

    // 并发搜索
    print('[SearchController] 开始搜索: "$trimmed", 可用源数=${validSources.length}');
    for (final s in validSources) {
      print('[SearchController] 源: key=${s.key}, type=${s.type}, api=${s.api}, isSpider=${s.isSpiderSource}');
    }

    final futures = <Future<void>>[];
    for (final source in validSources) {
      futures.add(_searchInSourceAndNotify(source, trimmed, requestId));
    }
    await Future.wait(futures);

    if (_latestSearchRequestId == requestId) {
      isSearching.value = false;
    }
  }

  Future<void> _searchInSourceAndNotify(
      SourceBean source, String kw, String requestId) async {
    try {
      print('[SearchController] 搜索源 ${source.key}: 开始搜索 "$kw"');
      final videos = await SourceService.instance.search(source, kw);
      print('[SearchController] 搜索源 ${source.key}: 返回 ${videos.length} 条结果');
      if (_latestSearchRequestId != requestId) return;
      resultsBySite[source.key] = videos;
      resultCount[source.key] = videos.length;
    } catch (e) {
      print('[SearchController] 搜索源 ${source.key}: 搜索失败 $e');
      if (_latestSearchRequestId != requestId) return;
      resultsBySite[source.key] = [];
      resultCount[source.key] = 0;
    }
    searchingStatus[source.key] = false;
  }

  Future<void> searchInSource(SourceBean source) async {
    final trimmed = keyword.value.trim();
    if (trimmed.isEmpty) return;

    searchingStatus[source.key] = true;
    resultCount[source.key] = 0;
    if (!activeSites.any((s) => s.key == source.key)) {
      activeSites.add(source);
    }
    selectedSiteKey.value = source.key;

    try {
      final videos = await SourceService.instance.search(source, trimmed);
      resultsBySite[source.key] = videos;
      resultCount[source.key] = videos.length;
    } catch (_) {
      resultsBySite[source.key] = [];
      resultCount[source.key] = 0;
    }
    searchingStatus[source.key] = false;
  }

  void selectSite(String key) {
    selectedSiteKey.value = key;
  }

  void loadSearchHistory() {
    _loadSearchHistoryAsync();
  }

  Future<void> _loadSearchHistoryAsync() async {
    final prefs = await SharedPreferences.getInstance();
    searchHistory.value = prefs.getStringList(AppConstants.searchHistory) ?? [];
  }

  Future<void> addToHistory(String kw) async {
    searchHistory.remove(kw);
    searchHistory.insert(0, kw);
    if (searchHistory.length > 20) {
      searchHistory.removeRange(20, searchHistory.length);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(AppConstants.searchHistory, searchHistory.toList());
  }

  Future<void> clearHistory() async {
    searchHistory.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppConstants.searchHistory);
  }
}
