import 'package:uuid/uuid.dart';

/// 电影/视频数据模型 - 对应 Swift Movie
class Movie {
  List<Video> videoList;
  int pagecount;
  int page;
  int total;
  int limit;

  Movie({
    this.videoList = const [],
    this.pagecount = 0,
    this.page = 0,
    this.total = 0,
    this.limit = 0,
  });

  factory Movie.fromJson(Map<String, dynamic> json) {
    return Movie(
      pagecount: json['pagecount'] as int? ?? 0,
      page: json['page'] as int? ?? 0,
      total: json['total'] as int? ?? 0,
      limit: json['limit'] as int? ?? 0,
      videoList: (json['list'] as List<dynamic>?)
              ?.map((e) => Video.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

/// 单个视频条目
class Video {
  /// 视频唯一 ID（接口可能返回 Int 或 String）
  String id;
  /// 片名
  String name;
  /// 海报地址
  String pic;
  /// 备注（如"更新至第20集"）
  String note;
  /// 年份
  String year;
  /// 地区
  String area;
  /// 类型/分类名
  String type;
  /// 导演
  String director;
  /// 演员
  String actor;
  /// 简介
  String des;
  /// 来源站点 key，用于跨源隔离收藏与历史
  String sourceKey;
  /// 分类 ID
  String tid;
  /// 最后更新时间
  String last;
  /// 播放来源信息（部分接口会复用该字段）
  String dt;

  Video({
    String? id,
    this.name = '',
    this.pic = '',
    this.note = '',
    this.year = '',
    this.area = '',
    this.type = '',
    this.director = '',
    this.actor = '',
    this.des = '',
    this.sourceKey = '',
    this.tid = '',
    this.last = '',
    this.dt = '',
  }) : id = id ?? const Uuid().v4();

  factory Video.fromJson(Map<String, dynamic> json) {
    return Video(
      id: _parseString(json['vod_id']),
      name: json['vod_name'] as String? ?? '',
      pic: json['vod_pic'] as String? ?? '',
      note: json['vod_remarks'] as String? ?? '',
      year: json['vod_year'] as String? ?? '',
      area: json['vod_area'] as String? ?? '',
      type: json['type_name'] as String? ?? '',
      director: json['vod_director'] as String? ?? '',
      actor: json['vod_actor'] as String? ?? '',
      des: json['vod_content'] as String? ?? '',
      sourceKey: json['sourceKey'] as String? ?? '',
      tid: _parseString(json['type_id']),
      last: json['vod_time'] as String? ?? '',
      dt: json['vod_play_from'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'vod_id': id,
      'vod_name': name,
      'vod_pic': pic,
      'vod_remarks': note,
      'vod_year': year,
      'vod_area': area,
      'type_name': type,
      'vod_director': director,
      'vod_actor': actor,
      'vod_content': des,
      'sourceKey': sourceKey,
      'type_id': tid,
      'vod_time': last,
      'vod_play_from': dt,
    };
  }

  /// 支持 String 或 Int 类型的字段解码
  static String _parseString(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is int) return value.toString();
    return value.toString();
  }
}
