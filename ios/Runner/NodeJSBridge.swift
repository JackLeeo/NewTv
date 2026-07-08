// NodeJSBridge.swift
// iOS 端 Node.js 集成 - Platform Channel 实现
// -----------------------------------------------------------------------------
// 通过 FlutterMethodChannel 暴露以下 method 给 Dart 端：
//   - startNodeJS({nativePort, sourcePath}) -> Bool
//   - stopNodeJS() -> Void
//   - getStatus() -> {isRunning, isNodeReady}
//   - setManagementPort(port: Int) -> Void   (Dart 同步 mgmt port 给 Swift)
//
// 调 NodeMobile.start(argc, argv) 启动 Node.js 进程。
// Node.js 进程退出时通过 channel 推 'onNodeExit' 给 Dart。
//
// **iOS SIGKILL 场景修复** (2026-07-08):
//   iOS 7分45秒后台后会 SIGKILL embed library, Swift `node_start` 阻塞不返回
//   → isRunning 卡 true + onNodeExit 不发 → Dart 不知道 Node.js 死了.
//   修复: Swift 监听 UIApplication.didBecomeActiveNotification, 每次 app
//   回前台 ping http://127.0.0.1:managementPort/check. 失败 → isRunning=false
//   + notifyDart('onNodeExit'). Dart onNodeExit 收到后清状态, handleSceneActive
//   看到 isRunning=false 调 startNodeJS 重启.
//
// **目录约定**：
//   - main.js 在 mainBundle 的 `nodejs-project/main.js`（workflow 嵌入）
//   - 用户源在 <Documents>/nodejs-project/src/source/（Dart 端写）
//
// **注意**：
//   - NodeMobile.h 只导出 `int node_start(int argc, char* argv[])`，没有 `node_exit`
//   - stopNodeJS 只能重置内部状态；Node.js 进程要自然退出或用户杀进程
//   - 参考 D:\lj\11\tvbox_project\ios\Runner\NodeJSManager.m 的 stopNodeJS 实现

import Foundation
import Flutter
import UIKit

@objc class NodeJSBridge: NSObject {

    // 与 lib/services/nodejs_platform_ios.dart 里的 channel name 保持一致
    static let channelName = "com.tvbox/flutter/nodejs"

    private let channel: FlutterMethodChannel
    private let messenger: FlutterBinaryMessenger
    private var isRunning: Bool = false
    private var managementPort: Int = 0   // Dart 同步过来的 mgmt port, foreground ping 用
    private let workQueue = DispatchQueue(label: "com.tvbox.nodejs",
                                          qos: .userInitiated)
    private var argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    private var argcCopy: Int = 0

    @objc init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        self.channel = FlutterMethodChannel(
            name: NodeJSBridge.channelName,
            binaryMessenger: messenger
        )
        super.init()
        self.channel.setMethodCallHandler { [weak self] (call, result) in
            self?.handle(call: call, result: result)
        }

        // **iOS SIGKILL 修复**: 监听 app 回前台, 主动 ping Node.js 确认是否还活着
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        print("[NodeJSBridge] 已注册 UIApplication.didBecomeActiveNotification 监听")
    }

    /// iOS app 回前台时触发 - 用于检测 Node.js 是否被 iOS SIGKILL
    @objc private func appDidBecomeActive() {
        print("[NodeJSBridge] app did become active, 检查 Node.js 健康")
        checkNodeJSHealth()
    }

    /// ping http://127.0.0.1:managementPort/check, 失败说明 Node.js 死了
    /// 死亡时清 isRunning + managementPort, 通知 Dart onNodeExit 触发恢复流程
    private func checkNodeJSHealth() {
        guard isRunning, managementPort > 0 else {
            print("[NodeJSBridge] skip health check: isRunning=\(isRunning) managementPort=\(managementPort)")
            return
        }
        let port = managementPort
        guard let url = URL(string: "http://127.0.0.1:\(port)/check") else {
            print("[NodeJSBridge] invalid health check URL")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        request.httpMethod = "GET"

        print("[NodeJSBridge] ping http://127.0.0.1:\(port)/check ...")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                print("[NodeJSBridge] ❌ Node.js health check 失败: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    print("[NodeJSBridge] Node.js 已死, 清状态 + 通知 Dart")
                    self.isRunning = false
                    self.managementPort = 0
                    self.notifyDart(method: "onNodeExit", arguments: 0)
                }
                return
            }
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                print("[NodeJSBridge] ✅ Node.js health check OK")
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("[NodeJSBridge] ❌ Node.js health check 异常 statusCode=\(code)")
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.managementPort = 0
                    self.notifyDart(method: "onNodeExit", arguments: 0)
                }
            }
        }.resume()
    }

    // ============================================================
    // Method call handler
    // ============================================================

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        print("[NodeJSBridge] received call: \(call.method)")
        switch call.method {
        case "startNodeJS":
            guard let args = call.arguments as? [String: Any],
                  let nativePort = args["nativePort"] as? Int,
                  let sourcePath = args["sourcePath"] as? String else {
                result(FlutterError(
                    code: "BAD_ARGS",
                    message: "startNodeJS 需要 {nativePort: Int, sourcePath: String}",
                    details: nil
                ))
                return
            }
            let ok = startNodeJS(nativePort: nativePort, sourcePath: sourcePath)
            result(ok)
        case "stopNodeJS":
            stopNodeJS()
            result(nil)
        case "setManagementPort":
            // Dart 收到 Node.js onCatPawOpenPort(mgmt) 时调,
            // Swift 存 managementPort 用于前台 ping 检测 Node.js 死活
            if let port = call.arguments as? Int {
                managementPort = port
                print("[NodeJSBridge] managementPort 同步: \(port)")
            }
            result(nil)
        case "getStatus":
            result([
                "isRunning": isRunning,
                "isNodeReady": isRunning   // 简化：iOS 端没有精确 ready 检测
            ])
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // ============================================================
    // Start / Stop
    // ============================================================

    /// 启动 Node.js
    ///
    /// 1. 在 mainBundle 找 main.js
    /// 2. 设置 NODE_PATH 环境变量
    /// 3. 构造 argv: [node, --security-revert=CVE-2023-46809, main.js, --native-port, port]
    /// 4. dispatch_async 到 work queue，调 `node_start(argc, argv)`
    /// 5. node_start 阻塞直到 Node.js 退出
    private func startNodeJS(nativePort: Int, sourcePath: String) -> Bool {
        if isRunning {
            print("[NodeJSBridge] 已经在运行中")
            return true
        }

        // 1. 找 main.js
        guard let scriptPath = locateMainScript() else {
            print("[NodeJSBridge] ❌ main.js 不在 bundle 中")
            return false
        }
        print("[NodeJSBridge] 找到 main.js: \(scriptPath)")

        // 2. NODE_PATH
        setenv("NODE_PATH", sourcePath, 1)

        // 3. 构造 argv
        //    node_start 的 argc 是 Int32 (即 C int)；
        //    argv 是 char** (CChar)；
        //    Swift 数组下标需要 Int，所以同时保留 Int 版本供循环用
        let args: [String] = [
            "node",
            "--security-revert=CVE-2023-46809",
            scriptPath,
            "--native-port",
            String(nativePort)
        ]
        let argcCount = args.count           // Int, 用于 Swift 数组下标
        let argc: Int32 = Int32(argcCount)   // Int32, 用于 node_start API
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(
            capacity: argcCount + 1
        )
        for i in 0..<argcCount {
            let cs = (args[i] as NSString).utf8String
            argv[i] = strdup(cs)
        }
        argv[argcCount] = nil

        isRunning = true

        // 4. 异步启动 Node.js
        workQueue.async { [weak self] in
            guard let self = self else { return }

            print("[NodeJSBridge] node_start(\(argc) args)")
            node_start(argc, argv)

            print("[NodeJSBridge] node_start 返回 (Node.js 退出)")

            // 释放 argv
            for i in 0..<argcCount {
                if let p = argv[i] { free(p) }
            }
            argv.deallocate()

            DispatchQueue.main.async {
                self.isRunning = false
                self.notifyDart(method: "onNodeExit", arguments: 0)
            }
        }

        return true
    }

    private func stopNodeJS() {
        // NodeMobile.h 只导出 node_start，没有 node_exit。
        // 实际可行的方案：
        //   - 只 reset 内部状态（isRunning = false），Node.js 进程继续跑；
        //   - 或者让 main.js 检测一个 IPC 信号主动退出。
        // 当前实现：reset 状态 + 通知 Dart。
        // iOS 进程被杀时 Node.js 也会被 SIGKILL。
        // 参考 D:\lj\11\tvbox_project\ios\Runner\NodeJSManager.m:507-515
        if isRunning {
            print("[NodeJSBridge] stopNodeJS: reset 内部状态（Node.js 进程仍在跑，需自然退出）")
            isRunning = false
            managementPort = 0
        }
    }

    // ============================================================
    // main.js 路径查找
    // ============================================================

    private func locateMainScript() -> String? {
        let bundle = Bundle.main
        // 优先尝试: nodejs-project/main.js（workflow 嵌入的目录）
        if let path = bundle.path(forResource: "main", ofType: "js", inDirectory: "nodejs-project") {
            return path
        }
        if let path = bundle.path(forResource: "main", ofType: "js", inDirectory: "dist") {
            return path
        }
        if let path = bundle.path(forResource: "index", ofType: "js", inDirectory: "nodejs-project") {
            return path
        }
        if let path = bundle.path(forResource: "index", ofType: "js", inDirectory: "dist") {
            return path
        }
        if let path = bundle.path(forResource: "main", ofType: "js") {
            return path
        }
        if let path = bundle.path(forResource: "index", ofType: "js") {
            return path
        }
        return nil
    }

    // ============================================================
    // Dart 通知
    // ============================================================

    private func notifyDart(method: String, arguments: Any?) {
        // 必须在主线程 invoke
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.channel.invokeMethod(method, arguments: arguments) { _ in }
        }
    }
}
