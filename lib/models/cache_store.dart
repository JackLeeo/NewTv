import 'dart:convert';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'movie.dart';

String makeVodBusinessKey(String vodId, String sourceKey) {
  final normalizedVodId = vodId.trim();
  final normalizedSourceKey = sourceKey.trim();
  return '$normalizedSourceKey::$normalizedVodId';
}

class VodPlaybackState {
  String flag;
  int episodeIndex;
  double progressSeconds;

  VodPlaybackState({
    required this.flag,
    required this.episodeIndex,
    required this.progressSeconds,
  });

  Map<String, dynamic> toJson() => {
        'flag': flag,
        'episodeIndex': episodeIndex,
        'progressSeconds': progressSeconds,
      };

  factory VodPlaybackState.fromJson(Map<String, dynamic> json) {
    return VodPlaybackState(
      flag: json['flag'] as String? ?? '',
      episodeIndex: json['episodeIndex'] as int? ?? 0,
      progressSeconds: (json['progressSeconds'] as num?)?.toDouble() ?? 0,
    );
  }
}

class VodCollect {
  String bizKey;
  String vodId;
  String vodName;
  String vodPic;
  String sourceKey;
  DateTime updateTime;

  VodCollect({
    required this.vodId,
    required this.vodName,
    required this.vodPic,
    required this.sourceKey,
  })  : bizKey = makeVodBusinessKey(vodId, sourceKey),
        updateTime = DateTime.now();

  factory VodCollect.fromJson(Map<String, dynamic> json) {
    final collect = VodCollect(
      vodId: json['vodId'] as String? ?? '',
      vodName: json['vodName'] as String? ?? '',
      vodPic: json['vodPic'] as String? ?? '',
      sourceKey: json['sourceKey'] as String? ?? '',
    );
    if (json['bizKey'] != null) {
      collect.bizKey = json['bizKey'] as String;
    }
    if (json['updateTime'] != null) {
      collect.updateTime = DateTime.parse(json['updateTime'] as String);
    }
    return collect;
  }

  Map<String, dynamic> toJson() => {
        'bizKey': bizKey,
        'vodId': vodId,
        'vodName': vodName,
        'vodPic': vodPic,
        'sourceKey': sourceKey,
        'updateTime': updateTime.toIso8601String(),
      };

  String get id => bizKey;
}

class VodRecord {
  String bizKey;
  String vodId;
  String vodName;
  String vodPic;
  String sourceKey;
  String playNote;
  String dataJson;
  DateTime updateTime;

  VodRecord({
    required this.vodId,
    required this.vodName,
    required this.vodPic,
    required this.sourceKey,
    this.playNote = '',
    this.dataJson = '',
  })  : bizKey = makeVodBusinessKey(vodId, sourceKey),
        updateTime = DateTime.now();

  factory VodRecord.fromJson(Map<String, dynamic> json) {
    final record = VodRecord(
      vodId: json['vodId'] as String? ?? '',
      vodName: json['vodName'] as String? ?? '',
      vodPic: json['vodPic'] as String? ?? '',
      sourceKey: json['sourceKey'] as String? ?? '',
      playNote: json['playNote'] as String? ?? '',
      dataJson: json['dataJson'] as String? ?? '',
    );
    if (json['bizKey'] != null) {
      record.bizKey = json['bizKey'] as String;
    }
    if (json['updateTime'] != null) {
      record.updateTime = DateTime.parse(json['updateTime'] as String);
    }
    return record;
  }

  Map<String, dynamic> toJson() => {
        'bizKey': bizKey,
        'vodId': vodId,
        'vodName': vodName,
        'vodPic': vodPic,
        'sourceKey': sourceKey,
        'playNote': playNote,
        'dataJson': dataJson,
        'updateTime': updateTime.toIso8601String(),
      };

  String get id => bizKey;
}

class CacheItem {
  String key;
  String value;
  DateTime updateTime;

  CacheItem({required this.key, required this.value})
      : updateTime = DateTime.now();

  factory CacheItem.fromJson(Map<String, dynamic> json) {
    final item = CacheItem(
      key: json['key'] as String? ?? '',
      value: json['value'] as String? ?? '',
    );
    if (json['updateTime'] != null) {
      item.updateTime = DateTime.parse(json['updateTime'] as String);
    }
    return item;
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'value': value,
        'updateTime': updateTime.toIso8601String(),
      };
}

class CacheStore {
  static final CacheStore _instance = CacheStore._internal();
  static CacheStore get instance => _instance;
  CacheStore._internal();

  static const String _collectsBoxName = 'vod_collects';
  static const String _recordsBoxName = 'vod_records';
  static const String _cacheItemsBoxName = 'cache_items';

  final favorites = <VodCollect>[].obs;
  final records = <VodRecord>[].obs;

  Box<dynamic>? _collectsBox;
  Box<dynamic>? _recordsBox;
  Box<dynamic>? _cacheItemsBox;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    _collectsBox = await Hive.openBox(_collectsBoxName);
    _recordsBox = await Hive.openBox(_recordsBoxName);
    _cacheItemsBox = await Hive.openBox(_cacheItemsBoxName);

    favorites.value = _loadFromBox<VodCollect>(_collectsBox!);
    records.value = _loadFromBox<VodRecord>(_recordsBox!);

    _initialized = true;
  }

  List<T> _loadFromBox<T>(Box<dynamic> box) {
    final items = <T>[];
    for (var i = 0; i < box.length; i++) {
      final raw = box.getAt(i);
      if (raw != null && raw is Map) {
        final map = Map<String, dynamic>.from(raw);
        if (T == VodCollect) {
          items.add(VodCollect.fromJson(map) as T);
        } else if (T == VodRecord) {
          items.add(VodRecord.fromJson(map) as T);
        }
      }
    }
    return items;
  }

  Future<void> _saveToBox<T>(List<T> items, Box<dynamic> box) async {
    await box.clear();
    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      Map<String, dynamic> json;
      if (item is VodCollect) {
        json = item.toJson();
      } else if (item is VodRecord) {
        json = item.toJson();
      } else {
        continue;
      }
      await box.put(i, json);
    }
  }

  Future<void> addCollect(Video video) async {
    final vodId = video.id;
    final sourceKey = video.sourceKey;
    final bizKey = makeVodBusinessKey(vodId, sourceKey);

    final items = List<VodCollect>.from(favorites);
    final matchedIndices = <int>[];
    for (int i = 0; i < items.length; i++) {
      if (items[i].bizKey == bizKey ||
          (items[i].bizKey.isEmpty &&
              items[i].vodId == vodId &&
              items[i].sourceKey == sourceKey)) {
        matchedIndices.add(i);
      }
    }

    if (matchedIndices.isNotEmpty) {
      final firstIndex = matchedIndices.first;
      items[firstIndex].bizKey = bizKey;
      items[firstIndex].vodName = video.name;
      items[firstIndex].vodPic = video.pic;
      items[firstIndex].updateTime = DateTime.now();
      // Remove duplicates (keep first, remove rest in reverse order)
      for (final index in matchedIndices.reversed.where((i) => i != firstIndex)) {
        items.removeAt(index);
      }
    } else {
      final collect = VodCollect(
        vodId: vodId,
        vodName: video.name,
        vodPic: video.pic,
        sourceKey: sourceKey,
      );
      items.insert(0, collect);
    }

    favorites.value = items;
    await _saveToBox(items, _collectsBox!);
  }

  Future<void> removeCollect(String vodId, String sourceKey) async {
    final bizKey = makeVodBusinessKey(vodId, sourceKey);
    favorites.removeWhere((item) =>
        item.bizKey == bizKey ||
        (item.bizKey.isEmpty &&
            item.vodId == vodId &&
            item.sourceKey == sourceKey));
    await _saveToBox(favorites.toList(), _collectsBox!);
  }

  bool isCollected(String vodId, String sourceKey) {
    final bizKey = makeVodBusinessKey(vodId, sourceKey);
    return favorites.any((item) =>
        item.bizKey == bizKey ||
        (item.bizKey.isEmpty &&
            item.vodId == vodId &&
            item.sourceKey == sourceKey));
  }

  Future<void> addRecord(
    Video video,
    String playNote, {
    VodPlaybackState? playbackState,
  }) async {
    final vodId = video.id;
    final sourceKey = video.sourceKey;
    final encodedState = _encodePlaybackState(playbackState);
    final bizKey = makeVodBusinessKey(vodId, sourceKey);

    final items = List<VodRecord>.from(records);
    final matchedIndices = <int>[];
    for (int i = 0; i < items.length; i++) {
      if (items[i].bizKey == bizKey ||
          (items[i].bizKey.isEmpty &&
              items[i].vodId == vodId &&
              items[i].sourceKey == sourceKey)) {
        matchedIndices.add(i);
      }
    }

    if (matchedIndices.isNotEmpty) {
      final firstIndex = matchedIndices.first;
      items[firstIndex].bizKey = bizKey;
      items[firstIndex].playNote = playNote;
      if (encodedState != null) {
        items[firstIndex].dataJson = encodedState;
      }
      items[firstIndex].updateTime = DateTime.now();
      // Remove duplicates (keep first, remove rest in reverse order)
      for (final index in matchedIndices.reversed.where((i) => i != firstIndex)) {
        items.removeAt(index);
      }
    } else {
      final record = VodRecord(
        vodId: vodId,
        vodName: video.name,
        vodPic: video.pic,
        sourceKey: sourceKey,
        playNote: playNote,
      );
      if (encodedState != null) {
        record.dataJson = encodedState;
      }
      items.insert(0, record);
    }

    records.value = items;
    await _saveToBox(items, _recordsBox!);
  }

  VodPlaybackState? getPlaybackState(String vodId, String sourceKey) {
    final bizKey = makeVodBusinessKey(vodId, sourceKey);
    final record = records.firstWhereOrNull((item) =>
        item.bizKey == bizKey ||
        (item.bizKey.isEmpty &&
            item.vodId == vodId &&
            item.sourceKey == sourceKey));
    if (record == null || record.dataJson.isEmpty) return null;
    return _decodePlaybackState(record.dataJson);
  }

  Future<void> clearHistory() async {
    records.value = [];
    await _saveToBox(<VodRecord>[], _recordsBox!);
  }

  Future<void> removeRecord(String vodId, String sourceKey) async {
    final bizKey = makeVodBusinessKey(vodId, sourceKey);
    records.removeWhere((item) =>
        item.bizKey == bizKey ||
        (item.bizKey.isEmpty &&
            item.vodId == vodId &&
            item.sourceKey == sourceKey));
    await _saveToBox(records.toList(), _recordsBox!);
  }

  Future<void> setCacheItem(String key, String value) async {
    final items = _loadCacheItems();
    final index = items.indexWhere((item) => item.key == key);
    if (index >= 0) {
      items[index].value = value;
      items[index].updateTime = DateTime.now();
    } else {
      items.add(CacheItem(key: key, value: value));
    }
    await _saveCacheItems(items);
  }

  String? getCacheItem(String key) {
    final items = _loadCacheItems();
    final item = items.firstWhereOrNull((item) => item.key == key);
    return item?.value;
  }

  Future<void> removeCacheItem(String key) async {
    final items = _loadCacheItems();
    items.removeWhere((item) => item.key == key);
    await _saveCacheItems(items);
  }

  List<CacheItem> _loadCacheItems() {
    final box = _cacheItemsBox!;
    final items = <CacheItem>[];
    for (var i = 0; i < box.length; i++) {
      final raw = box.getAt(i);
      if (raw != null && raw is Map) {
        items.add(CacheItem.fromJson(Map<String, dynamic>.from(raw)));
      }
    }
    return items;
  }

  Future<void> _saveCacheItems(List<CacheItem> items) async {
    final box = _cacheItemsBox!;
    await box.clear();
    for (int i = 0; i < items.length; i++) {
      await box.put(i, items[i].toJson());
    }
  }

  static String? _encodePlaybackState(VodPlaybackState? state) {
    if (state == null) return null;
    return jsonEncode(state.toJson());
  }

  static VodPlaybackState? _decodePlaybackState(String json) {
    try {
      return VodPlaybackState.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}
