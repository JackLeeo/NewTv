import 'dart:async';

import 'package:dlna_dart/dlna.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// DLNA 投屏 page
///
/// **参考**：PiliPlus-main/lib/pages/dlna/view.dart
///
/// 用法：
/// ```dart
/// Get.toNamed('/dlna', parameters: {
///   'url': playUrl,
///   'title': videoTitle,
/// });
/// ```
///
/// 流程：
/// 1. initState → DLNAManager.start()，开始扫描局域网内 DLNA/UPnP 设备
/// 2. 监听 devices.stream 实时显示新发现的设备
/// 3. 30 秒后自动 stop（避免长时间占用网络）
/// 4. 用户点击某个设备 → 调 device.setUrl(url, title) + device.play()
/// 5. 二次点击同一设备 → return（避免重复投屏）
class DLNAPage extends StatefulWidget {
  const DLNAPage({super.key});

  @override
  State<DLNAPage> createState() => _DLNAPageState();
}

class _DLNAPageState extends State<DLNAPage> {
  final DLNAManager _searcher = DLNAManager();
  final Map<String, DLNADevice> _deviceList = {};
  late final String _url = Get.parameters['url'] ?? '';
  late final String? _title = Get.parameters['title'];

  StreamSubscription? _devicesSub;
  Timer? _stopTimer;
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _onSearch(isInit: true);
  }

  /// 启动 / 重新搜索
  ///
  /// [isInit] = true 表示页面初始化（不清空设备列表，保留旧列表等待新设备加入）
  /// [isInit] = false 表示用户手动点刷新（清空设备列表重新扫描）
  Future<void> _onSearch({bool isInit = false}) async {
    if (_isSearching) return;
    _isSearching = true;

    if (!isInit && mounted) {
      setState(() => _deviceList.clear());
    }

    try {
      final deviceManager = await _searcher.start();
      if (!mounted) return;
      // 30 秒后自动停止搜索
      _stopTimer?.cancel();
      _stopTimer = Timer(const Duration(seconds: 30), () {
        _searcher.stop();
        if (mounted) setState(() => _isSearching = false);
      });

      // 监听设备流
      _devicesSub?.cancel();
      _devicesSub = deviceManager.devices.stream.listen((deviceList) {
        if (mounted) {
          setState(() => _deviceList.addAll(deviceList));
        }
      });
    } catch (e) {
      debugPrint('DLNA start failed: $e');
      if (mounted) setState(() => _isSearching = false);
    }
  }

  @override
  void dispose() {
    _stopTimer?.cancel();
    _stopTimer = null;
    _devicesSub?.cancel();
    _devicesSub = null;
    _searcher.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('投屏（DLNA）'),
        actions: [
          IconButton(
            tooltip: '重新搜索',
            onPressed: _onSearch,
            icon: const Icon(Icons.refresh, color: Colors.white),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: _buildBody(colorScheme),
    );
  }

  Widget _buildBody(ColorScheme colorScheme) {
    if (_isSearching && _deviceList.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text('正在搜索局域网内的 DLNA 设备…',
                style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }
    if (_deviceList.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.tv_off, size: 64, color: Colors.white24),
            const SizedBox(height: 16),
            const Text('没有发现 DLNA 设备',
                style: TextStyle(color: Colors.white70, fontSize: 16)),
            const SizedBox(height: 8),
            const Text(
              '请确认：\n'
              '1. 电视/投影仪与手机连接同一 WiFi\n'
              '2. 设备已开启 DLNA / AirPlay / Miracast 功能',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 24),
            TextButton.icon(
              onPressed: _onSearch,
              icon: const Icon(Icons.refresh),
              label: const Text('重新搜索'),
            ),
          ],
        ),
      );
    }
    final keys = _deviceList.keys.toList();
    return ListView.separated(
      itemCount: keys.length + (_isSearching ? 1 : 0),
      separatorBuilder: (_, __) =>
          Divider(height: 1, color: Colors.white.withValues(alpha: 0.05)),
      itemBuilder: (context, index) {
        if (index == keys.length) {
          // 列表底部"还在搜索"提示
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: Text('继续搜索中…',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
            ),
          );
        }
        final key = keys[index];
        final device = _deviceList[key]!;
        return ListTile(
          leading: const Icon(Icons.tv, color: Colors.white70),
          title: Text(
            device.info.friendlyName,
            style: const TextStyle(color: Colors.white),
          ),
          subtitle: Text(key,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4), fontSize: 11)),
          trailing: const Icon(Icons.cast, color: Colors.white54),
          onTap: () => _castTo(device, key),
        );
      },
    );
  }

  Future<void> _castTo(DLNADevice device, String key) async {
    if (_url.isEmpty) {
      Get.snackbar('投屏失败', '视频地址为空', snackPosition: SnackPosition.BOTTOM);
      return;
    }
    try {
      // setUrl 把视频 URL 推到 DMR；play 触发 DMR 开始播放
      await device.setUrl(_url, title: _title ?? '');
      await device.play();
      if (!mounted) return;
      Get.snackbar(
        '投屏成功',
        '正在 ${device.info.friendlyName} 上播放：${_title ?? ''}',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 3),
        backgroundColor: Colors.black87,
        colorText: Colors.white,
      );
    } catch (e) {
      debugPrint('DLNA cast failed: $e');
      if (!mounted) return;
      Get.snackbar('投屏失败', '$e',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red.shade700,
          colorText: Colors.white);
    }
  }
}
