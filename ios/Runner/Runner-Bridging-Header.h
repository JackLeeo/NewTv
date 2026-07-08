#import "GeneratedPluginRegistrant.h"

// NodeMobile 框架（来自 nodejs-mobile fork: https://github.com/JackLeeo/nodejs-mobile）
// iOS 端 Node.js 嵌入方案的核心 API
// - node_start(int argc, char** argv) - 启动 Node.js 主循环（阻塞）
// - node_exit(int code) - 让 Node.js 主循环 graceful exit (不杀 host app)
// - node_is_running() - 检查 Node.js 是否还在跑 (1=在跑, 0=没跑)
//   **2026-07-08 方案 B**: 用 node_exit 实现 stop+restart 循环, 解决
//   iOS 7分45秒后台 SIGKILL embed library 后无法重启 Node.js 的问题.
//   关键: node_exit 同步 block 直到 V8 thread 完全退出, 紧接着 node_start
//   可以启动新 Node.js 实例 (新 listen socket).
// pbxproj 必须 link NodeMobile.xcframework（由 ruby 脚本自动改）
#import <NodeMobile/NodeMobile.h>
