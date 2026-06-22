/// 分类排序模型 - 对应 Swift MovieSort
class MovieSort {
  /// 分类列表（包含首页推荐、影视分类等）
  List<SortData> sortList;

  MovieSort({this.sortList = const []});
}

/// 单个分类数据
class SortData {
  /// 分类唯一标识（接口字段通常为 type_id）
  final String id;
  /// 分类显示名
  final String name;
  /// 标记位（不同源可定义不同语义，常用于首页/推荐标识）
  final String flag;
  /// 分类下可选筛选项（年份、地区、类型等）
  final List<SortFilter> filters;

  const SortData({
    this.id = '',
    this.name = '',
    this.flag = '',
    this.filters = const [],
  });

  /// 生成首页推荐占位分类。
  /// 该分类不走常规分类接口，直接渲染首页推荐列表。
  static SortData home() {
    return const SortData(id: 'home', name: '推荐', flag: '1');
  }

  factory SortData.fromJson(
      Map<String, dynamic> json, Map<String, List<SortFilter>> filtersMap) {
    final id = _parseId(json['type_id']);
    return SortData(
      id: id,
      name: json['type_name'] as String? ?? '',
      flag: json['flag'] as String? ?? '',
      filters: filtersMap[id] ?? [],
    );
  }

  static String _parseId(dynamic value) {
    if (value == null) return '';
    if (value is int) return value.toString();
    return value.toString();
  }
}

/// 筛选条件
class SortFilter {
  /// 接口参数键，例如 year、area
  final String key;
  /// UI 展示名称
  final String name;
  /// 可选值集合
  final List<SortFilterValue> values;

  const SortFilter({
    this.key = '',
    this.name = '',
    this.values = const [],
  });

  factory SortFilter.fromJson(Map<String, dynamic> json) {
    return SortFilter(
      key: json['key'] as String? ?? '',
      name: json['name'] as String? ?? '',
      values: (json['value'] as List<dynamic>?)
              ?.map((e) => SortFilterValue.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

/// 筛选条件值
class SortFilterValue {
  /// 展示名
  final String n;
  /// 真实参数值
  final String v;

  const SortFilterValue({this.n = '', this.v = ''});

  factory SortFilterValue.fromJson(Map<String, dynamic> json) {
    return SortFilterValue(
      n: json['n'] as String? ?? '',
      v: json['v'] as String? ?? '',
    );
  }
}
