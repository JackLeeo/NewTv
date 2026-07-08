// BackgroundAudio.swift
// iOS Background Audio 模式 - 让 Node.js 进程在 app 后台 / 锁屏时不被 iOS SIGKILL
// -----------------------------------------------------------------------------
// **方案 A (2026-07-08)**:
//   原理: 在 app 启动时激活 AVAudioSession + 用 AVAudioEngine 持续播放
//   静音 buffer. iOS 检测到 app 在播放 audio, 维持 app 在 active 状态,
//   不会因为进入后台或锁屏而杀 embed library (Node.js 进程).
//
//   这是 Apple 官方允许的 background mode 之一 (Info.plist UIBackgroundModes
//   包含 'audio'). iOS 把 app 当作"audio app"对待, 保持后台运行.
//
//   副作用:
//     - 锁屏时 control center / status bar 会显示 app 正在播放 audio
//     - 持续播放约 30 分钟后 iOS 17+ 可能会向用户发提示 (本地巨魔安装不受影响)
//     - 极小 CPU 电量消耗 (纯静音 buffer 调度)
//
// **iOS SIGKILL 场景的根因**:
//   iOS 17+ 在 app 长时间 (7-8 分钟) 后台后会 SIGKILL embed library (Node.js 进程).
//   此时 Swift `node_start` 阻塞不返回 + isRunning 卡 true + onNodeExit 不发.
//   用 background audio 模式, app 不会被 iOS 当作"已挂起", 进程继续运行.
//   Node.js 的 V8 isolate + uv loop + listen socket 都活着, 切回前台时
//   数据还在.
//
// **实现**:
//   - AVAudioSession .playback category (不请求 microphone 权限)
//   - AVAudioEngine 持续 schedule 静音 PCM buffer (loops)
//   - 在 app 进入后台 / 锁屏前再次激活 session (保险)
//   - 在 app 回前台时也保持播放 (避免被 iOS 重新评估)

import Foundation
import AVFoundation
import UIKit

class BackgroundAudio {

    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isStarted = false
    private let queue = DispatchQueue(label: "com.tvbox.background-audio")

    static let shared = BackgroundAudio()

    private init() {}

    /// 启动 silent audio playback. 在 app 启动早期 (didFinishLaunching) 调.
    /// 可以重复调, 第二次起 no-op.
    func start() {
        queue.sync {
            if isStarted {
                NSLog("[BackgroundAudio] already started, skip")
                return
            }

            do {
                // 1. 配置 audio session - playback category
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(
                    .playback,
                    mode: .default,
                    options: []  // 不需要 .mixWithOthers (我们是唯一 audio source)
                )
                try session.setActive(true, options: [])
                NSLog("[BackgroundAudio] AVAudioSession activated (.playback)")

                // 2. 创建静音 buffer
                guard let format = AVAudioFormat(
                    standardFormatWithSampleRate: 22050,
                    channels: 1
                ) else {
                    NSLog("[BackgroundAudio] ❌ failed to create AVAudioFormat")
                    return
                }

                let frameCapacity: AVAudioFrameCount = 4096
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: frameCapacity
                ) else {
                    NSLog("[BackgroundAudio] ❌ failed to create PCM buffer")
                    return
                }
                buffer.frameLength = frameCapacity
                // buffer 默认全是 0 (静音), 不需要 fill

                // 3. Attach + connect + start engine
                audioEngine.attach(player)
                audioEngine.connect(
                    player,
                    to: audioEngine.mainMixerNode,
                    format: format
                )
                try audioEngine.start()
                NSLog("[BackgroundAudio] AVAudioEngine started")

                // 4. Schedule buffer 循环播放
                player.scheduleBuffer(
                    buffer,
                    at: nil,
                    options: .loops,
                    completionHandler: nil
                )
                player.play()
                NSLog("[BackgroundAudio] player.play() called, looping silent buffer")

                // 5. 监听 interruption (e.g., 来电) - 重新激活
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleInterruption(_:)),
                    name: AVAudioSession.interruptionNotification,
                    object: nil
                )

                // 6. 监听 route change (耳机拔掉) - 不需要 stop
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleRouteChange(_:)),
                    name: AVAudioSession.routeChangeNotification,
                    object: nil
                )

                isStarted = true
                NSLog("[BackgroundAudio] ✅ silent audio started, app can run in background")
            } catch {
                NSLog("[BackgroundAudio] ❌ start failed: \(error.localizedDescription)")
            }
        }
    }

    /// 停止 (e.g., app 真正退出时)
    func stop() {
        queue.sync {
            guard isStarted else { return }
            player.stop()
            audioEngine.stop()
            try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation)
            isStarted = false
            NSLog("[BackgroundAudio] stopped")
        }
    }

    /// app 进入后台前再次激活 session (保险)
    /// iOS 在某些情况下会 deactivate audio session, 重新激活以确保保持
    @objc func appWillResignActive() {
        NSLog("[BackgroundAudio] app will resign active, re-activate session")
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    @objc func appDidEnterBackground() {
        NSLog("[BackgroundAudio] app did enter background, ensure audio playing")
        if isStarted && !player.isPlaying {
            NSLog("[BackgroundAudio] player stopped, restart")
            player.play()
        }
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    @objc func appWillEnterForeground() {
        NSLog("[BackgroundAudio] app will enter foreground, re-activate session")
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        switch type {
        case .began:
            NSLog("[BackgroundAudio] interruption began, pause")
            player.pause()
        case .ended:
            NSLog("[BackgroundAudio] interruption ended, resume")
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        // route change 不需要 stop, 但要重新激活 session
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}
