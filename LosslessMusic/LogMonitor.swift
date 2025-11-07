import Foundation
import Cocoa // For NSWorkspace

// MARK: - QualityInfo Struct
/// 存储从日志中解析出的音频格式信息
struct QualityInfo: Equatable, CustomStringConvertible {
    var bitDepth: UInt32 = 0
    var sampleRate: Double = 0.0 // 单位: kHz, 例如 96.0
    var numChannels: UInt32 = 0
    var asbdFormatId: String = ""

    static func == (lhs: QualityInfo, rhs: QualityInfo) -> Bool {
        return lhs.bitDepth == rhs.bitDepth &&
               lhs.sampleRate == rhs.sampleRate &&
               lhs.numChannels == rhs.numChannels &&
               lhs.asbdFormatId == rhs.asbdFormatId
    }

    func isValid() -> Bool {
        return bitDepth > 0 && sampleRate > 0 && numChannels > 0 && !asbdFormatId.isEmpty
    }

    var description: String {
        return "\(bitDepth)bit, \(numChannels) channels, \(sampleRate)kHz \(asbdFormatId)"
    }
}

// MARK: - LogMonitor Class
/// 一个完全自包含的类，通过监听日志来自动检测曲目变化和音频格式，并在正确的时机触发回调。
class LogMonitor {

    private var process: Process?
    private var pipe: Pipe?

    // --- 正则表达式 ---
    private let mediaFormatPattern = /play\> cm\>> mediaFormatinfo.*lossless,/
    private let bitDepthPattern = /sdBitDepth = (\d+)/
    private let sampleRatePattern = /asbdSampleRate = (\d+(?:\.\d+)?)/
    private let formatIdPattern = /asbdFormatID = (\w+)/
    private let numChannelsPattern = /asbdNumChannels = (\d+)/
    // 用于从日志中直接匹配新曲目开始播放的日志
    private let newTrackPattern = /(?:preparer success|created AVPlayerItem).*'(.*)'/

    // --- 状态机核心变量 ---
    private var pendingQualityInfo: QualityInfo?
    private var currentTrackTitle: String? // 从日志中解析出的曲目标题
    private var didSwitchForCurrentTrack = false
    
    var newFormatDetected: ((_ channels: UInt32, _ bitDepth: UInt32, _ sampleRate: Double, _ formatId: String) -> Void)?

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            print("System woke up, restarting log monitoring.")
            self?.restartMonitoring()
        }
        startMonitoring()
    }

    deinit {
        stopMonitoring()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func startMonitoring() {
        guard process?.isRunning != true else { return }
        
        process = Process()
        pipe = Pipe()

        process?.launchPath = "/usr/bin/log"
        // 谓词必须足够宽泛，以同时捕获曲目变更和格式信息的日志
        process?.arguments = [
            "stream",
            "--predicate", "subsystem == 'com.apple.Music' AND category == 'ampplay'",
        ]
        process?.standardOutput = pipe

        pipe?.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let logMessage = String(data: data, encoding: .utf8), !logMessage.isEmpty {
                DispatchQueue.global(qos: .userInitiated).async {
                    logMessage.split(separator: "\n").forEach { line in
                        self?.processLogLine(String(line))
                    }
                }
            }
        }

        process?.terminationHandler = { [weak self] _ in
            print("Log process terminated unexpectedly. Restarting...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.restartMonitoring() }
        }

        do {
            try process?.run()
            print("Log monitoring started successfully.")
        } catch {
            print("Failed to launch log stream process: \(error)")
        }
    }

    func stopMonitoring() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        pipe = nil
        print("Log monitoring stopped.")
    }

    func restartMonitoring() {
        stopMonitoring()
        startMonitoring()
    }
    
    /// 核心处理函数，根据日志内容驱动状态机
    private func processLogLine(_ line: String) {
        // --- 事件1: 检测到新曲目 ---
        if let match = line.firstMatch(of: newTrackPattern) {
            let newTrackTitle = String(match.1)
            
            if newTrackTitle != self.currentTrackTitle {
                print("--- Track Change Detected (from Log): \(newTrackTitle) ---")
                self.currentTrackTitle = newTrackTitle
                self.didSwitchForCurrentTrack = false

                if let pendingInfo = self.pendingQualityInfo {
                    print("Applying pending quality info for the new track.")
                    triggerFormatChange(with: pendingInfo)
                    self.pendingQualityInfo = nil
                }
            }
        // --- 事件2: 检测到音频格式信息 ---
        } else if line.contains(mediaFormatPattern) {
            var newQuality = QualityInfo()
            if let m = line.firstMatch(of: bitDepthPattern) { newQuality.bitDepth = UInt32(m.1) ?? 0 }
            if let m = line.firstMatch(of: sampleRatePattern) { newQuality.sampleRate = Double(m.1) ?? 0.0 }
            if let m = line.firstMatch(of: numChannelsPattern) { newQuality.numChannels = UInt32(m.1) ?? 0 }
            if let m = line.firstMatch(of: formatIdPattern) { newQuality.asbdFormatId = String(m.1) }
            
            guard newQuality.isValid() else { return }
            print(">>> Media Format Detected: \(newQuality)")

            if currentTrackTitle != nil && !didSwitchForCurrentTrack {
                print("Applying new quality info for the current track.")
                triggerFormatChange(with: newQuality)
            } else {
                print("Storing quality info as pending for the next track.")
                if self.pendingQualityInfo != newQuality {
                    self.pendingQualityInfo = newQuality
                }
            }
        }
    }

    private func triggerFormatChange(with quality: QualityInfo) {
        guard !didSwitchForCurrentTrack else { return }

        print("✅ Requesting format change to: \(quality) for track: \(currentTrackTitle ?? "unknown")")
        self.didSwitchForCurrentTrack = true

        DispatchQueue.main.async { [weak self] in
            self?.newFormatDetected?(
                quality.numChannels, quality.bitDepth, quality.sampleRate * 1000, quality.asbdFormatId
            )
        }
    }
}
