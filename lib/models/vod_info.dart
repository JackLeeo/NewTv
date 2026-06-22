import 'movie.dart';

/// 视频详情模型 - 对应 Swift VodInfo
class VodInfo {
  /// 视频唯一 ID
  String id;
  /// 标题
  String name;
  /// 海报地址
  String pic;
  /// 备注（更新状态等）
  String note;
  /// 年份
  String year;
  /// 地区
  String area;
  /// 类型名
  String typeName;
  /// 导演
  String director;
  /// 演员
  String actor;
  /// 简介
  String des;
  /// 来源站点 key
  String sourceKey;

  /// 播放来源（线路）列表
  List<String> playFlags;

  /// key: flag名称, value: 剧集列表
  Map<String, List<Episode>> playUrlMap;

  /// 当前选中线路
  String playFlag;

  /// 当前播放剧集索引
  int playIndex;

  VodInfo({
    required this.id,
    this.name = '',
    this.pic = '',
    this.note = '',
    this.year = '',
    this.area = '',
    this.typeName = '',
    this.director = '',
    this.actor = '',
    this.des = '',
    this.sourceKey = '',
    this.playFlags = const [],
    this.playUrlMap = const {},
    this.playFlag = '',
    this.playIndex = 0,
  });

  /// 当前线路下的剧集
  List<Episode> get currentEpisodes => playUrlMap[playFlag] ?? [];

  /// 当前线路 + 当前索引对应的剧集对象
  Episode? get currentEpisode {
    final eps = currentEpisodes;
    if (playIndex < 0 || playIndex >= eps.length) return null;
    return eps[playIndex];
  }

  /// 从 Movie.Video 和详情数据构建
  static VodInfo fromVideo({
    required Video video,
    required String playFrom,
    required String playUrl,
  }) {
    final info = VodInfo(
      id: video.id,
      name: video.name,
      pic: video.pic,
      note: video.note,
      year: video.year,
      area: video.area,
      typeName: video.type,
      director: video.director,
      actor: video.actor,
      des: _stripHtml(video.des),
      sourceKey: video.sourceKey,
    );

    // 解析播放列表：
    // playFrom 格式: "线路1$$$线路2$$$线路3"
    // playUrl  格式: "第1集$url1#第2集$url2$$$第1集$url3#第2集$url4"
    final flags = playFrom.split('\$\$\$').where((s) => s.isNotEmpty).toList();
    final urls = playUrl.split('\$\$\$');

    info.playFlags = flags;
    info.playUrlMap = {};
    for (int i = 0; i < flags.length; i++) {
      if (i < urls.length) {
        final episodes = urls[i]
            .split('#')
            .map((item) {
              final parts = item.split('\$');
              if (parts.length >= 2) {
                return Episode(name: parts[0], url: parts[1]);
              }
              return null;
            })
            .whereType<Episode>()
            .toList();
        info.playUrlMap[flags[i]] = episodes;
      }
    }

    if (flags.isNotEmpty) {
      info.playFlag = flags.first;
    }

    return info;
  }

  static String _stripHtml(String text) {
    return text.replaceAll(RegExp(r'<[^>]+>'), '');
  }
}

/// 单集信息
class Episode {
  /// 集标题
  final String name;
  /// 集播放地址
  final String url;

  const Episode({required this.name, required this.url});
}
