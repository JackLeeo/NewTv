// NodeJSBridge.swift
// iOS 端 Node.js 集成 - Platform Channel 实现
// -----------------------------------------------------------------------------
// 通过 FlutterMethodChannel 暴露以下 method 给 Dart 端：
//   - startNodeJS({nativePort, sourcePath}) -> Bool
//   - stopNodeJS() -> Void
//   - getStatus() -> {isRunning, isNodeReady}
//
// 调 NodeMobile.start(argc, argv) 启动 Node.js 进程。
// Node.js 进程退出时通过 channel 推 'onNodeExit' 给 Dart。
//
// **目录约定**：
//   - main.js 在 mainBundle 的 `nodejs-project/main.js`（workflow 嵌入）
//   - 用户源在 <Documents>/nodejs-project/src/source/（Dart 端写）

import Foundation
import Flutter

@objc class NodeJSBridge: NSObject {

    // 与 lib/services/nodejs_platform_ios.dart 里的 channel name 保持一致
    static let channelName = "com.tvbox/flutter/nodejs"

    private let channel: FlutterMethodChannel
    private let messenger: FlutterBinaryMessenger
    private var isRunning: Bool = false
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
        let args: [String] = [
            "node",
            "--security-revert=CVE-2023-46809",
            scriptPath,
            "--native-port",
            String(nativePort)
        ]
        let argc = args.count
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(
            capacity: argc + 1
        )
        for i in 0..<argc {
            let cs = (args[i] as NSString).utf8String
            argv[i] = strdup(cs)
        }
        argv[argc] = nil

        isRunning = true

        // 4. 异步启动 Node.js
        workQueue.async { [weak self] in
            guard let self = self else { return }

            print("[NodeJSBridge] node_start(\(argc) args)")
            node_start(argc, argv)

            print("[NodeJSBridge] node_start 返回 (Node.js 退出)")

            // 释放 argv
            for i in 0..<argc {
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
        // NodeMobile 提供的退出方式：
        //   - node_exit(int code) - 让 Node.js 主循环退出
        // 某些版本可能没有 node_exit，最粗暴的做法是 abort()
        // 这里用 node_exit(0)（NodeMobile.h 中声明）
        if isRunning {
            print("[NodeJSBridge] stopNodeJS: 调 node_exit(0)")
            node_exit(0)
            isRunning = false
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
