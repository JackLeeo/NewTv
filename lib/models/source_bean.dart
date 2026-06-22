/// 视频源站点配置 - 对应 Swift SourceBean
class SourceBean {
  /// 源唯一键
  final String key;
  /// 源显示名
  final String name;
  /// 源接口地址
  final String api;
  /// 搜索开关：0 关闭，1 开启
  final int searchable;
  /// 是否允许出现在首页分类：0 不可选，1 可选
  final int filterable;
  /// 快速搜索开关：0 关闭，1 开启
  final int quickSearch;
  /// 源声明的播放器类型
  final int playerType;
  /// 源协议类型：0 XML，1 JSON，3 JAR，4 Remote
  final int type;
  /// 扩展参数（remote 源常用）
  final String? ext;
  /// JAR 包 URL（Spider 源常用）
  final String? jar;
  /// 索引标记：1 表示索引服务（如豆瓣），点击视频应跳转搜索
  final int indexs;

  const SourceBean({
    this.key = '',
    this.name = '',
    this.api = '',
    this.searchable = 1,
    this.filterable = 1,
    this.quickSearch = 0,
    this.playerType = 0,
    this.type = 1,
    this.ext,
    this.jar,
    this.indexs = 0,
  });

  bool get isSearchable => searchable == 1;
  bool get isFilterable => filterable == 1;
  bool get isQuickSearchEnabled => quickSearch == 1;

  bool get isSupportedInSwift => type == 0 || type == 1 || type == 3 || type == 4;

  bool get isSpiderSource => type == 3;

  bool get isIndexSite => indexs == 1 || key == 'douban';

  bool get isConfigCenter => key == 'baseset';

  /// 类型描述
  String get typeDescription {
    switch (type) {
      case 0:
        return 'XML';
      case 1:
        return 'JSON';
      case 3:
        return 'Spider';
      case 4:
        return 'Remote';
      default:
        return '未知';
    }
  }

  /// api 字段是否为有效 HTTP URL
  bool get isHttpApi => api.startsWith('http://') || api.startsWith('https://');

  factory SourceBean.fromJson(Map<String, dynamic> json) {
    return SourceBean(
      key: json['key'] as String? ?? '',
      name: json['name'] as String? ?? '',
      api: json['api'] as String? ?? '',
      searchable: _parseInt(json['searchable']),
      filterable: _parseInt(json['filterable']),
      quickSearch: _parseInt(json['quickSearch']),
      playerType: _parseInt(json['playerType']),
      type: _parseInt(json['type']),
      ext: _parseExt(json['ext']),
      jar: json['jar'] as String?,
      indexs: _parseInt(json['indexs']),
    );
  }

  static int _parseInt(dynamic value) {
    if (value == null) return 1;
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 1;
    return 1;
  }

  static String? _parseExt(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    if (value is Map) return value.toString();
    return value.toString();
  }
}
