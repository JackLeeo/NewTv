# NewTv · 跨平台 TVBox 视频播放器

> **最终成品：iOS 巨魔 IPA**（[TrollStore](https://github.com/opa334/TrollStore) 安装，无需 Apple 签名）
> **开发机：Windows**（用 `.node.exe` 提前发现 bug，降低 iOS 调试成本）

基于 **Flutter** + **Node.js** 远程源 + **media_kit** 视频播放的跨平台 TVBox 客户端。

---

## ✨ 功能

- 📺 **远程源加载**：用户在设置页输入远程源 URL（`.js` + `.js.md5`），自动 MD5 校验 + 缓存，断网时使用本地缓存
- 🎬 **视频播放**：基于 [media_kit](https://github.com/media-kit/media-kit) + libmpv，硬件解码、字幕、音轨切换
- 🔍 **资源搜索**：整合视频源 + 网盘（阿里、夸克、UC）搜索
- 🕷️ **多爬虫架构**：Node.js 服务端跑爬虫，Dart 端通过 HTTP 拿到结构化数据
- 💾 **多源管理**：第一次输入 URL 后写入本地缓存，下次启动自动加载
- ⚙️ **设置中心**：源 URL 变更、缓存清理、连接管理、错误日志查看

---

## 📦 平台支持

| 平台 | 状态 | Node.js 集成方式 | 安装包 |
|---|---|---|---|
| **iOS（巨魔）** | ✅ 主要成品 | 嵌入 [NodeMobile.xcframework](https://github.com/nodejs-mobile/nodejs-mobile) v18.20.4 | TrollStore IPA（伪签） |
| **Windows** | ✅ 开发机 | `Process.start(node.exe)` + 按需下载 | Inno Setup `.exe`（自包含安装器） |
| **Android** | ⏳ 架构占位 | 待补 libnode.a + JNI 桥 | — |

> **设计取舍**：因为 iOS 沙盒拒绝任意 `.node.exe`，必须用 Apple 接受的 [NodeMobile](https://github.com/nodejs-mobile/nodejs-mobile) framework。Windows 用 `.node.exe` 是为了在开发机上提前发现 bug（跨端共用同一套 Node.js 业务代码），降低 iOS 调试成本。

---

## 🏗️ 跨平台架构

```
┌─────────────────────────────────────────────────────────────┐
│  Flutter Dart 端（跨端统一）                                  │
│  ┌─────────────────┐  ┌──────────────────┐  ┌────────────┐  │
│  │ NodeJSManager   │  │ dart:io          │  │ UI / GetX  │  │
│  │  (Platform.isXxx│  │ HttpServer 收    │  │            │  │
│  │   选 platform)  │  │ Node.js 通知     │  │            │  │
│  └────────┬────────┘  └──────────────────┘  └────────────┘  │
│           │                                                  │
│  ┌────────┴──────────────────────────────────────────────┐  │
│  │ NodeJSPlatform (abstract)                             │  │
│  │  startNodeJS / stopNodeJS / loadSource / 路径         │  │
│  └────┬──────────────┬───────────────────┬───────────────┘  │
│       │              │                   │                   │
│  ┌────▼─────┐  ┌─────▼──────┐  ┌─────────▼─────┐            │
│  │ Windows  │  │ iOS        │  │ Android       │            │
│  │ Process  │  │ MethodChan │  │ 占位          │            │
│  │ .start() │  │ → Swift →  │  │ throw UIE     │            │
│  │ node.exe │  │ node_start │  │               │            │
│  └────┬─────┘  └─────┬──────┘  └───────────────┘            │
└───────┼──────────────┼──────────────────────────────────────┘
        │              │
   ┌────▼─────┐   ┌────▼──────────────┐
   │ node.exe │   │ NodeMobile.xcframework
   │ (下载)   │   │ (嵌入 bundle)     │
   └──────────┘   └───────────────────┘
```

详细见 [lib/services/nodejs_platform.dart](lib/services/nodejs_platform.dart) 接口定义，以及三个实现：

- [nodejs_platform_windows.dart](lib/services/nodejs_platform_windows.dart) — `Process.start` + 运行时下载
- [nodejs_platform_ios.dart](lib/services/nodejs_platform_ios.dart) — `MethodChannel` 调 Swift
- [nodejs_platform_android.dart](lib/services/nodejs_platform_android.dart) — 占位（throw `UnimplementedError`）

iOS native 端：

- [ios/Runner/NodeJSBridge.swift](ios/Runner/NodeJSBridge.swift) — 调 `node_start(argc, argv)` 启动 Node.js
- [ios/Runner/Runner-Bridging-Header.h](ios/Runner/Runner-Bridging-Header.h) — `import <NodeMobile/NodeMobile.h>`
- [ios/Runner/AppDelegate.swift](ios/Runner/AppDelegate.swift) — 在 `didInitializeImplicitFlutterEngine` 注册 channel
- [ios/scripts/add_nodemobile.rb](ios/scripts/add_nodemobile.rb) — ruby `xcodeproj` gem 自动 link + embed NodeMobile

---

## 🚀 快速开始

### 前置依赖

- Flutter 3.24.0+（[stable channel](https://docs.flutter.dev/release/archive)）
- Dart 3.12.0+
- **Windows 端额外**：[Media Player](https://support.microsoft.com/en-us/windows/media-player)（libmpv 运行时需要）
- **iOS 端额外**：[TrollStore](https://github.com/opa334/TrollStore) 装到主控设备

### 本地运行

```bash
# 1. 装依赖
flutter pub get

# 2. 跑 Windows 端
flutter run -d windows

# 3. 跑 iOS 端（需要 macOS + Xcode）
flutter run -d ios
```

### 第一次使用

1. 启动 App，看到「请输入远程源 URL」提示
2. 输入你的 TVBox 源地址（`.js` 结尾，例如 `https://example.com/tvbox/index.js`）
3. App 自动下载源文件，缓存到本地
4. 下次启动自动加载（先校验 MD5，不一致才重新下载）

### 重置源

进入 **设置 → 重置配置**，清空本地缓存，回到初始输入页。

---

## 📦 打包

### Windows 自包含安装器

```bash
# 1. Build Flutter app
flutter build windows --release

# 2. 编译安装器（PowerShell）
# 工具在 tools/installer/Installer.cs
# 详见 tools/installer/README.md
```

安装器会：
- 引导用户选安装路径（不默认 `C:\Program Files\`）
- 内嵌 `app.zip`（Flutter 产物 + 资源）
- 首次启动检查 Node.js 运行时，缺失则按需下载

### iOS 巨魔 IPA

```bash
# 在 GitHub 上手动触发 .github/workflows/ios.yml
# 工作流会自动：
# 1. checkout
# 2. setup Flutter (stable)
# 3. brew install ldid
# 4. pub get
# 5. esbuild main.js（Node.js 业务代码）
# 6. 下载 NodeMobile.xcframework
# 7. ruby 脚本自动改 pbxproj link NodeMobile
# 8. flutter build ios --no-codesign
# 9. 嵌入 NodeMobile + main.js 到 Runner.app
# 10. ldid 伪签主 app + framework
# 11. 打 IPA
# 12. 上传 artifact
```

触发 workflow 后下载 IPA，丢进 TrollStore 装到设备。

---

## 🛠️ 技术栈

| 层级 | 选型 |
|---|---|
| UI 框架 | Flutter 3.24+ |
| 状态管理 | [GetX](https://pub.dev/packages/get) 4.6 |
| HTTP | [Dio](https://pub.dev/packages/dio) 5.4 |
| 本地存储 | [Hive CE](https://pub.dev/packages/hive_ce) 2.19 |
| 视频播放 | [media_kit](https://github.com/media-kit/media-kit) 1.1 + libmpv |
| 桌面窗口 | [window_manager](https://pub.dev/packages/window_manager) |
| Node.js 嵌入 | [NodeMobile](https://github.com/nodejs-mobile/nodejs-mobile) v18.20.4（iOS） |
| Node.js 运行时 | [Node.js](https://nodejs.org) v20.11.1（Windows 按需下载） |
| 巨魔伪签 | [ldid](https://github.com/saurik/ldid)（Saurik） |
| pbxproj 自动化 | ruby [xcodeproj](https://github.com/CocoaPods/Xcodeproj) gem |

---

## 🤝 贡献

欢迎提 issue / PR。请确保：

1. 修改后 `flutter analyze` 0 error
2. 跨端兼容（Windows 端验证基础功能，iOS 端验证 platform channel）
3. 业务代码改动同步更新 `assets/nodejs-project/src/`

---

## 📜 许可证

[MIT](LICENSE)

---

## 🙏 致谢

- [media_kit](https://github.com/media-kit/media-kit) — Flutter 视频播放
- [NodeMobile](https://github.com/nodejs-mobile/nodejs-mobile) — iOS 端 Node.js 嵌入
- [TrollStore](https://github.com/opa334/TrollStore) — 巨魔 IPA 安装
- [ldid](https://github.com/saurik/ldid) — ad-hoc 伪签
- [tvbox 社区](https://github.com/qist/tvbox) — TVBox 爬虫生态
