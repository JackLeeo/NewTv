import 'dart:convert';

/// 灵活类型解码器 - 兼容 JSON 中数值字段可能是字符串 "0" 或整数 0 的情况

/// 兼容 JSON 中数值字段可能是字符串或整数
class FlexibleInt {
  final int value;

  const FlexibleInt(this.value);

  factory FlexibleInt.fromJson(dynamic json) {
    if (json is int) return FlexibleInt(json);
    if (json is String) return FlexibleInt(int.tryParse(json) ?? 0);
    return const FlexibleInt(0);
  }

  int toJson() => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlexibleInt && runtimeType == other.runtimeType && value == other.value;

  @override
  int get hashCode => value.hashCode;
}

/// 兼容 ext 字段可能是字符串或对象
class FlexibleExt {
  final String? stringValue;
  final Map<String, AnyCodableValue>? dictValue;

  const FlexibleExt({this.stringValue, this.dictValue});

  factory FlexibleExt.fromJson(dynamic json) {
    if (json is String) {
      return FlexibleExt(stringValue: json);
    }
    if (json is Map<String, dynamic>) {
      return FlexibleExt(
        dictValue: json.map((k, v) => MapEntry(k, AnyCodableValue.fromJson(v))),
      );
    }
    return const FlexibleExt();
  }

  dynamic toJson() {
    if (stringValue != null) return stringValue;
    if (dictValue != null) {
      return dictValue!.map((k, v) => MapEntry(k, v.toJson()));
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlexibleExt &&
          runtimeType == other.runtimeType &&
          stringValue == other.stringValue;

  @override
  int get hashCode => stringValue.hashCode;
}

/// 通用的 JSON 值类型，用于处理混合类型的字典
enum AnyCodableType { string, int_, double_, bool_, dict, array, null_ }

class AnyCodableValue {
  final AnyCodableType _type;
  final String? _stringValue;
  final int? _intValue;
  final double? _doubleValue;
  final bool? _boolValue;
  final Map<String, AnyCodableValue>? _dictValue;
  final List<AnyCodableValue>? _arrayValue;

  const AnyCodableValue._({
    required AnyCodableType type,
    String? stringValue,
    int? intValue,
    double? doubleValue,
    bool? boolValue,
    Map<String, AnyCodableValue>? dictValue,
    List<AnyCodableValue>? arrayValue,
  })  : _type = type,
        _stringValue = stringValue,
        _intValue = intValue,
        _doubleValue = doubleValue,
        _boolValue = boolValue,
        _dictValue = dictValue,
        _arrayValue = arrayValue;

  factory AnyCodableValue.string(String s) =>
      AnyCodableValue._(type: AnyCodableType.string, stringValue: s);
  factory AnyCodableValue.int_(int i) =>
      AnyCodableValue._(type: AnyCodableType.int_, intValue: i);
  factory AnyCodableValue.double_(double d) =>
      AnyCodableValue._(type: AnyCodableType.double_, doubleValue: d);
  factory AnyCodableValue.bool_(bool b) =>
      AnyCodableValue._(type: AnyCodableType.bool_, boolValue: b);
  factory AnyCodableValue.dict(Map<String, AnyCodableValue> d) =>
      AnyCodableValue._(type: AnyCodableType.dict, dictValue: d);
  factory AnyCodableValue.array(List<AnyCodableValue> a) =>
      AnyCodableValue._(type: AnyCodableType.array, arrayValue: a);
  factory AnyCodableValue.null_() =>
      const AnyCodableValue._(type: AnyCodableType.null_);

  factory AnyCodableValue.fromJson(dynamic json) {
    if (json is String) return AnyCodableValue.string(json);
    if (json is int) return AnyCodableValue.int_(json);
    if (json is double) return AnyCodableValue.double_(json);
    if (json is bool) return AnyCodableValue.bool_(json);
    if (json is Map<String, dynamic>) {
      return AnyCodableValue.dict(
        json.map((k, v) => MapEntry(k, AnyCodableValue.fromJson(v))),
      );
    }
    if (json is List) {
      return AnyCodableValue.array(
        json.map((e) => AnyCodableValue.fromJson(e)).toList(),
      );
    }
    return AnyCodableValue.null_();
  }

  dynamic toJson() {
    switch (_type) {
      case AnyCodableType.string:
        return _stringValue;
      case AnyCodableType.int_:
        return _intValue;
      case AnyCodableType.double_:
        return _doubleValue;
      case AnyCodableType.bool_:
        return _boolValue;
      case AnyCodableType.dict:
        return _dictValue?.map((k, v) => MapEntry(k, v.toJson()));
      case AnyCodableType.array:
        return _arrayValue?.map((e) => e.toJson()).toList();
      case AnyCodableType.null_:
        return null;
    }
  }

  /// 将可能的任意类型转换为字符串（如果原本是字典或数组，则转为 JSON 字符串）
  String? get stringValue {
    switch (_type) {
      case AnyCodableType.string:
        return _stringValue;
      case AnyCodableType.int_:
        return _intValue?.toString();
      case AnyCodableType.double_:
        return _doubleValue?.toString();
      case AnyCodableType.bool_:
        return _boolValue == true ? 'true' : 'false';
      case AnyCodableType.null_:
        return null;
      case AnyCodableType.dict:
      case AnyCodableType.array:
        try {
          return jsonEncode(toJson());
        } catch (_) {
          return null;
        }
    }
  }

  bool get isString => _type == AnyCodableType.string;
  bool get isNull => _type == AnyCodableType.null_;
  bool get isDict => _type == AnyCodableType.dict;

  Map<String, AnyCodableValue>? get dictValue => _dictValue;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AnyCodableValue &&
          runtimeType == other.runtimeType &&
          _type == other._type &&
          _stringValue == other._stringValue &&
          _intValue == other._intValue &&
          _doubleValue == other._doubleValue &&
          _boolValue == other._boolValue;

  @override
  int get hashCode => Object.hash(_type, _stringValue, _intValue, _doubleValue, _boolValue);
}

// MARK: - 解析接口配置

/// 解析接口配置 - 对应 Swift ParseBean
class ParseBean {
  final String name;
  final String url;
  /// 0:嗅探 1:解析
  final int type;
  final Map<String, String>? ext;

  const ParseBean({
    this.name = '',
    this.url = '',
    this.type = 0,
    this.ext,
  });

  factory ParseBean.fromJson(Map<String, dynamic> json) {
    return ParseBean(
      name: json['name'] as String? ?? '',
      url: json['url'] as String? ?? '',
      type: _parseInt(json['type']),
      ext: _parseExtMap(json['ext']),
    );
  }

  static int _parseInt(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  static Map<String, String>? _parseExtMap(dynamic value) {
    if (value == null) return null;
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
    return null;
  }
}

// MARK: - API 配置顶层结构

/// API 配置顶层结构 - 对应 JSON 配置文件格式
class AppConfigData {
  final String? spider;
  final String? wallpaper;
  final List<SiteConfig>? sites;
  final List<ParseConfig>? parses;
  final List<LiveConfig>? lives;
  final List<DoHConfig>? doh;
  final List<RuleConfig>? rules;
  final List<String>? hosts;
  final List<String>? flags;
  final List<String>? ads;

  const AppConfigData({
    this.spider,
    this.wallpaper,
    this.sites,
    this.parses,
    this.lives,
    this.doh,
    this.rules,
    this.hosts,
    this.flags,
    this.ads,
  });

  factory AppConfigData.fromJson(Map<String, dynamic> json) {
    return AppConfigData(
      spider: json['spider'] as String?,
      wallpaper: json['wallpaper'] as String?,
      sites: (json['sites'] as List<dynamic>?)
          ?.map((e) => SiteConfig.fromJson(e as Map<String, dynamic>))
          .toList(),
      parses: (json['parses'] as List<dynamic>?)
          ?.map((e) => ParseConfig.fromJson(e as Map<String, dynamic>))
          .toList(),
      lives: (json['lives'] as List<dynamic>?)
          ?.map((e) => LiveConfig.fromJson(e as Map<String, dynamic>))
          .toList(),
      doh: (json['doh'] as List<dynamic>?)
          ?.map((e) => DoHConfig.fromJson(e as Map<String, dynamic>))
          .toList(),
      rules: (json['rules'] as List<dynamic>?)
          ?.map((e) => RuleConfig.fromJson(e as Map<String, dynamic>))
          .toList(),
      hosts: (json['hosts'] as List<dynamic>?)?.cast<String>(),
      flags: (json['flags'] as List<dynamic>?)?.cast<String>(),
      ads: (json['ads'] as List<dynamic>?)?.cast<String>(),
    );
  }

  /// 是否包含可直接加载的核心内容
  bool get hasUsableContent {
    final hasSites = sites?.isNotEmpty ?? false;
    final hasLives = lives?.isNotEmpty ?? false;
    final hasParses = parses?.isNotEmpty ?? false;
    return hasSites || hasLives || hasParses;
  }
}

class SiteConfig {
  final String? key;
  final String? name;
  final String? api;
  final FlexibleInt? searchable;
  final FlexibleInt? filterable;
  final FlexibleInt? quickSearch;
  final FlexibleInt? playerType;
  final FlexibleInt? type;
  final FlexibleInt? indexs;
  final AnyCodableValue? ext;
  final String? jar;
  final AnyCodableValue? style;
  final String? playUrl;
  final List<String>? categories;
  final String? click;

  const SiteConfig({
    this.key,
    this.name,
    this.api,
    this.searchable,
    this.filterable,
    this.quickSearch,
    this.playerType,
    this.type,
    this.indexs,
    this.ext,
    this.jar,
    this.style,
    this.playUrl,
    this.categories,
    this.click,
  });

  factory SiteConfig.fromJson(Map<String, dynamic> json) {
    return SiteConfig(
      key: json['key'] as String?,
      name: json['name'] as String?,
      api: json['api'] as String?,
      searchable: json['searchable'] != null
          ? FlexibleInt.fromJson(json['searchable'])
          : null,
      filterable: json['filterable'] != null
          ? FlexibleInt.fromJson(json['filterable'])
          : null,
      quickSearch: json['quickSearch'] != null
          ? FlexibleInt.fromJson(json['quickSearch'])
          : null,
      playerType: json['playerType'] != null
          ? FlexibleInt.fromJson(json['playerType'])
          : null,
      type: json['type'] != null ? FlexibleInt.fromJson(json['type']) : null,
      indexs: json['indexs'] != null ? FlexibleInt.fromJson(json['indexs']) : null,
      ext: json['ext'] != null ? AnyCodableValue.fromJson(json['ext']) : null,
      jar: json['jar'] as String?,
      style: json['style'] != null ? AnyCodableValue.fromJson(json['style']) : null,
      playUrl: json['playUrl'] as String?,
      categories: (json['categories'] as List<dynamic>?)?.cast<String>(),
      click: json['click'] as String?,
    );
  }
}

class ParseConfig {
  final String? name;
  final String? url;
  final FlexibleInt? type;
  final FlexibleExt? ext;

  const ParseConfig({this.name, this.url, this.type, this.ext});

  factory ParseConfig.fromJson(Map<String, dynamic> json) {
    return ParseConfig(
      name: json['name'] as String?,
      url: json['url'] as String?,
      type: json['type'] != null ? FlexibleInt.fromJson(json['type']) : null,
      ext: json['ext'] != null ? FlexibleExt.fromJson(json['ext']) : null,
    );
  }
}

class LiveConfig {
  final String? name;
  final String? url;
  final FlexibleInt? type;
  final String? ua;
  final String? epg;
  final String? logo;
  final AnyCodableValue? pass;
  final FlexibleInt? playerType;
  final List<LiveChannelConfig>? channels;

  const LiveConfig({
    this.name,
    this.url,
    this.type,
    this.ua,
    this.epg,
    this.logo,
    this.pass,
    this.playerType,
    this.channels,
  });

  factory LiveConfig.fromJson(Map<String, dynamic> json) {
    return LiveConfig(
      name: json['name'] as String?,
      url: json['url'] as String?,
      type: json['type'] != null ? FlexibleInt.fromJson(json['type']) : null,
      ua: json['ua'] as String?,
      epg: json['epg'] as String?,
      logo: json['logo'] as String?,
      pass: json['pass'] != null ? AnyCodableValue.fromJson(json['pass']) : null,
      playerType: json['playerType'] != null
          ? FlexibleInt.fromJson(json['playerType'])
          : null,
      channels: (json['channels'] as List<dynamic>?)
          ?.map((e) => LiveChannelConfig.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class LiveChannelConfig {
  final String? name;
  final List<String>? urls;
  final String? group;
  final String? logo;

  const LiveChannelConfig({this.name, this.urls, this.group, this.logo});

  factory LiveChannelConfig.fromJson(Map<String, dynamic> json) {
    return LiveChannelConfig(
      name: json['name'] as String?,
      urls: (json['urls'] as List<dynamic>?)?.cast<String>(),
      group: json['group'] as String?,
      logo: json['logo'] as String?,
    );
  }
}

class DoHConfig {
  final String? name;
  final String? url;

  const DoHConfig({this.name, this.url});

  factory DoHConfig.fromJson(Map<String, dynamic> json) {
    return DoHConfig(
      name: json['name'] as String?,
      url: json['url'] as String?,
    );
  }
}

class RuleConfig {
  final String? name;
  final String? host;
  final List<String>? hosts;
  final List<String>? rule;
  final List<String>? regex;
  final List<String>? filter;
  final List<String>? script;

  const RuleConfig({
    this.name,
    this.host,
    this.hosts,
    this.rule,
    this.regex,
    this.filter,
    this.script,
  });

  factory RuleConfig.fromJson(Map<String, dynamic> json) {
    return RuleConfig(
      name: json['name'] as String?,
      host: json['host'] as String?,
      hosts: (json['hosts'] as List<dynamic>?)?.cast<String>(),
      rule: (json['rule'] as List<dynamic>?)?.cast<String>(),
      regex: (json['regex'] as List<dynamic>?)?.cast<String>(),
      filter: (json['filter'] as List<dynamic>?)?.cast<String>(),
      script: (json['script'] as List<dynamic>?)?.cast<String>(),
    );
  }
}

/// 多仓库合并索引配置（如 tvboxmulti.json）
class MultiRepoConfigData {
  final List<MultiRepoEntry>? urls;

  const MultiRepoConfigData({this.urls});

  factory MultiRepoConfigData.fromJson(Map<String, dynamic> json) {
    return MultiRepoConfigData(
      urls: (json['urls'] as List<dynamic>?)
          ?.map((e) => MultiRepoEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  List<String> get candidateUrls {
    return urls
            ?.map((e) => e.url?.trim() ?? '')
            .where((url) => url.isNotEmpty)
            .toList() ??
        [];
  }
}

class MultiRepoEntry {
  final String? name;
  final String? url;

  const MultiRepoEntry({this.name, this.url});

  factory MultiRepoEntry.fromJson(Map<String, dynamic> json) {
    return MultiRepoEntry(
      name: json['name'] as String?,
      url: json['url'] as String?,
    );
  }
}
