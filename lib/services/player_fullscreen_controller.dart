import 'package:get/get.dart';

/// 全屏状态控制器 - 全局单例
///
/// **背景**: iOS 上 WindowFullScreen.enter() 是 no-op, native fullscreen 不能
/// 覆盖其他 Scaffold. 之前 detail view 自己监听 onFullScreenChanged 来切换
/// immersive (隐藏 AppBar + body 黑色), 但 app.dart 根 Scaffold 的 bottom
/// navigation bar (首页/直播/历史/收藏/设置) 不会感知, 导致直播页全屏时
/// 底栏依然显示.
///
/// **修复**: 任何 video 全屏时, 把自己注册到这个全局 Rx, app.dart 监听
/// 该 Rx 隐藏 bottom navigation bar. detail view 内部已经处理 AppBar 隐藏,
/// 这里只解决"根 Scaffold 的底栏".
class PlayerFullscreenController extends GetxController {
  static PlayerFullscreenController get instance => Get.find();

  /// true = 有视频处于全屏 (app.dart 用它隐藏底栏)
  final isFullscreen = false.obs;

  /// 上一个全屏的 ID, 用于"在 detail A 全屏 → 切到 detail B 全屏"时
  /// 避免 setState 顺序问题. 当前实现下只用 bool 就够.
  void enter(String sourceId) {
    isFullscreen.value = true;
  }

  void exit(String sourceId) {
    isFullscreen.value = false;
  }
}
