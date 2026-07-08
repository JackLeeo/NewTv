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
import Darwin  // dlsym

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

    // **2026-07-08 方案 B (Patch NodeMobile) runtime detection**:
    //   旧 framework (janeasystems/nodejs-mobile 官方版 v18.20.4) 没有 node_exit 符号.
    //   新 framework (JackLeeo/nodejs-mobile fork) 才有.
    //   用 dlsym 查符号, 不存在时降级到"只 reset 状态"逻辑.
    //   这样: 测试期用旧 framework 不会 crash, patch framework 编译完后才走 graceful exit.
    //
    // **RTLD_DEFAULT in Swift**:
    //   Darwin 的 RTLD_DEFAULT 是 C 宏 ((void*) -2), Swift 编译器
    //   "Cannot find 'RTLD_DEFAULT' in scope". 直接用数值 -2 避免 import 麻烦.
    //   Darwin.dlfcn.h: #define RTLD_DEFAULT ((void *) -2)
    private static let RTLD_DEFAULT_PTR = UnsafeMutableRawPointer(bitPattern: -2)
    private typealias NodeExitFunc = @convention(c) (Int32) -> Void
    private lazy var nodeExitPtr: NodeExitFunc? = {
        guard let sym = dlsym(Self.RTLD_DEFAULT_PTR, "node_exit") else {
            print("[NodeJSBridge] ⚠️ node_exit 符号未找到 (旧 framework?), 降级到 reset 状态")
            return nil
        }
        return unsafeBitCast(sym, to: NodeExitFunc.self)
    }()
    private typealias NodeIsRunningFunc = @convention(c) () -> Int32
    private lazy var nodeIsRunningPtr: NodeIsRunningFunc? = {
        guard let sym = dlsym(Self.RTLD_DEFAULT_PTR, "node_is_running") else { return nil }
        return unsafeBitCast(sym, to: NodeIsRunningFunc.self)
    }()

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

        // **2026-07-08 node.log 诊断**: 把 iOS Documents 沙盒下的 node.log 路径
        // 通过 argv 传给 main.js, main.js 启动时 fs.appendFileSync 重定向
        // console.log/error. 用来诊断 force_restart 后新 Node.js 静默 crash
        // (iOS SIGKILL 场景 Swift node_start 返 true 但 Node.js 立即 exit
        // 没有任何 onCatPawOpenPort/onMessage 通知 Dart 的根因)
        let documentsDir = NSSearchPathForDirectoriesInDomains(
            .documentDirectory, .userDomainMask, true).first ?? ""
        let nodejsProjectDir = "\(documentsDir)/nodejs-project"
        let nodeLogPath = "\(nodejsProjectDir)/runtime/node.log"
        // 确保 runtime 目录存在, 避免 main.js appendFileSync 时 ENOENT
        let fm = FileManager.default
        let runtimeDir = "\(nodejsProjectDir)/runtime"
        if !fm.fileExists(atPath: runtimeDir) {
            try? fm.createDirectory(
                atPath: runtimeDir, withIntermediateDirectories: true)
        }
        print("[NodeJSBridge] node.log path: \(nodeLogPath)")

        // 3. 构造 argv
        //    node_start 的 argc 是 Int32 (即 C int)；
        //    argv 是 char** (CChar)；
        //    Swift 数组下标需要 Int，所以同时保留 Int 版本供循环用
        let args: [String] = [
            "node",
            "--security-revert=CVE-2023-46809",
            scriptPath,
            "--native-port",
            String(nativePort),
            "--node-log-path",
            nodeLogPath,
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
        // **2026-07-08 方案 B (Patch NodeMobile) + 方案 A (Background Audio)**:
        // 用 NodeMobile 暴露的 node_exit() 调 graceful shutdown V8 + libuv.
        // node_exit 同步 block 直到 V8 thread 完全退出 (workQueue 上的
        // node_start 跑完 cleanup + TearDownOncePerProcess), 然后返回.
        // 紧接着 Swift 通知 Dart onNodeExit, Dart 收到后会调 startNodeJS
        // 重启 Node.js (新 isolate + 新 listen socket).
        //
        // **降级兼容旧 framework**:
        //   dlsym 找不到 node_exit 符号 (用旧 janeasystems 官方版) 时,
        //   走 "只 reset 状态" 逻辑. Node.js 进程继续跑, 用户杀 app 时一起死.
        //   这种情况由 Background Audio (方案 A) 兜底, 避免 SIGKILL.
        if isRunning {
            if let nodeExit = nodeExitPtr {
                print("[NodeJSBridge] stopNodeJS: 调 node_exit(0) graceful shutdown V8")
                // **关键**: node_exit 必须在非 workQueue thread 调 (workQueue 上跑
                // node_start, node_exit 在同一个 thread 调会死锁). MethodChannel
                // 回调默认 main thread, 所以这里是 main thread, 安全.
                // node_exit 内部会 spin wait 直到 V8 thread 跑完, 通常 500ms-2s.
                let startTime = Date()
                nodeExit(0)
                let elapsed = Date().timeIntervalSince(startTime)
                print("[NodeJSBridge] node_exit(0) 返回, V8 已退出 (耗时 \(String(format: "%.2f", elapsed))s)")
            } else {
                print("[NodeJSBridge] stopNodeJS: ⚠️ node_exit 不可用, 降级 reset 状态 (依赖 Background Audio 防 SIGKILL)")
            }

            isRunning = false
            managementPort = 0
            // 通知 Dart, 触发 handleSceneActive 走 restart_needed 路径
            notifyDart(method: "onNodeExit", arguments: 0)
        } else {
            print("[NodeJSBridge] stopNodeJS: 状态 isRunning=false, 无需 stop")
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
