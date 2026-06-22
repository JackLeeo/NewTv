import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // NodeJSBridge 持有 platform channel
  private var nodeJSBridge: NodeJSBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    application.applicationSupportsShakeToEdit = false // Disable shake to undo
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    // 注册 Flutter 生态的所有插件
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // 注册 NodeJSBridge（iOS 端 Node.js 集成的 platform channel）
    //
    // FlutterImplicitEngineBridge 协议不直接暴露 binaryMessenger 属性，
    // 但暴露 pluginRegistry；通过 registrar(forPlugin:).messenger() 可以拿到
    // FlutterBinaryMessenger，这是 Flutter 标准的插件注册方式。
    //
    // 参考：
    //   - D:\lj\11\tvbox_project\ios\Runner\AppDelegate.swift（旧的 FlutterViewController 模式）
    //   - Flutter 官方插件开发：registrar.messenger() 是 binaryMessenger 的标准来源
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NodeJSBridge") {
      self.nodeJSBridge = NodeJSBridge(messenger: registrar.messenger())
    } else {
      print("[AppDelegate] ❌ 无法获取 NodeJSBridge 的 registrar")
    }
  }
}
