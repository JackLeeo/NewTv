/// 直播相关模型 - 对应 Swift LiveModels

/// 直播频道分组
class LiveChannelGroup {
  /// 分组名称（如"央视""卫视"）
  String groupName;
  /// 分组在列表中的顺序索引
  int groupIndex;
  /// 分组下频道列表
  List<LiveChannelItem> channels;
  /// 是否为加密分组（当前实现仅保留字段，未启用密码校验）
  bool isPassword;

  LiveChannelGroup({
    this.groupName = '',
    this.groupIndex = 0,
    this.channels = const [],
    this.isPassword = false,
  });

  /// 以分组名作为稳定标识
  String get id => groupName;
}

/// 直播频道
class LiveChannelItem {
  /// 频道名
  String channelName;
  /// 频道在分组内的顺序索引
  int channelIndex;
  /// 多线路播放地址
  List<String> channelUrls;
  /// 当前选中的线路索引
  int sourceIndex;
  /// 台标地址（预留）
  String logo;

  LiveChannelItem({
    this.channelName = '',
    this.channelIndex = 0,
    this.channelUrls = const [],
    this.sourceIndex = 0,
    this.logo = '',
  });

  /// 频道标识由名称+索引组成，规避同名频道冲突
  String get id => '${channelName}_$channelIndex';

  /// 可用线路总数
  int get sourceNum => channelUrls.length;

  /// 当前线路对应的播放地址。
  /// 当索引越界时兜底返回第一条线路，避免直接播放失败。
  String? get currentUrl {
    if (sourceIndex < 0 || sourceIndex >= channelUrls.length) {
      return channelUrls.isNotEmpty ? channelUrls.first : null;
    }
    return channelUrls[sourceIndex];
  }

  /// 轮换到下一条线路
  void nextSource() {
    if (channelUrls.isNotEmpty) {
      sourceIndex = (sourceIndex + 1) % channelUrls.length;
    }
  }
}

/// EPG 节目信息
class Epginfo {
  String title;
  String startTime;
  String endTime;
  int index;

  Epginfo({
    this.title = '',
    this.startTime = '',
    this.endTime = '',
    this.index = 0,
  });

  String get id => '${title}_$startTime';

  /// 根据 HH:mm 时间段判断节目是否正在播出
  bool get isLive {
    final now = DateTime.now();
    final startMinutes = _parseTime(startTime);
    final endMinutes = _parseTime(endTime);
    final nowMinutes = now.hour * 60 + now.minute;

    if (startMinutes == null || endMinutes == null) return false;
    return nowMinutes >= startMinutes && nowMinutes < endMinutes;
  }

  static int? _parseTime(String timeStr) {
    final parts = timeStr.split(':');
    if (parts.length < 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    return hour * 60 + minute;
  }
}

/// EPG 日期分组
class LiveEpgDate {
  /// 供 UI 展示的日期文案
  String datePresent;
  /// 供接口查询的原始日期值
  String date;
  /// 在日期列表中的位置索引
  int index;
  /// 是否被当前 UI 选中
  bool isSelected;

  LiveEpgDate({
    this.datePresent = '',
    this.date = '',
    this.index = 0,
    this.isSelected = false,
  });

  String get id => datePresent;
}
