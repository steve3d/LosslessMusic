//
//  LogMonitor.swift
//  LosslessMusic
//
//  Created by Steve Yin on 2025/4/24.
//

import AppKit
import CoreAudio
import OSLog

struct QualityInfo: Equatable, CustomStringConvertible {

    var bitDepth: UInt32 = 0
    var sampleRate: Double = 0.0
    var numChannels: UInt32 = 0
    var asbdFormatId: String = ""

    static func == (lhs: QualityInfo, rhs: QualityInfo) -> Bool {
        return UInt32(lhs.sampleRate) == UInt32(rhs.sampleRate)
            || lhs.bitDepth == rhs.bitDepth
    }

    func isValid() -> Bool {
        return bitDepth > 0 && sampleRate > 0 && numChannels > 0
            && asbdFormatId != ""
    }

    var description: String {
        return "\(bitDepth)bit, \(numChannels) channels, \(sampleRate)kHz \(asbdFormatId)"
    }

    mutating func reset() {
        bitDepth = 0
        sampleRate = 0.0
        numChannels = 0
        asbdFormatId = ""
    }
}

class LogMonitor {

    private var process: Process?
    private var pipe: Pipe?
    private var defaultDeviceId: AudioDeviceID = 0

    // media format info for lossless only
    private let mediaFormatPattern = /play\> cm\>> mediaFormatinfo.*lossless,/

    private let bitDepthPattern = /sdBitDepth = (\d+)/
    private let sampleRatePattern = /asbdSampleRate = (\d+(?:\.\d+)?)/
    private let formatIdPattern = /asbdFormatID = (\w+)/
    private let numChannelsPattern = /asbdNumChannels = (\d+)/

    private var lastNewFormatAt = 0.0
    private var qualityInfo = QualityInfo()
    private var currentPlayingItemId: String?
    private var playingStartedAt = Date().timeIntervalSinceReferenceDate

    // Callback for media start to play, use call back for extreme simple solution
    // 1. nbChannels
    // 2. bitDepth
    // 3. sampleRate
    // 4. mediaFormatId
    var newFormatDetected: ((UInt32, UInt32, Double, String) -> Void)?

    init() {
        // After system wake up, log stream might be dead, so restart it
        let workspace = NSWorkspace.shared

        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("System woke up, restart monitoring.")
            self?.restartMonitoring()
        }

        startMonitoring()
    }

    deinit {
        // Terminate the process when the monitor is deallocated
        stopMonitoring()
    }

    func startMonitoring() {
        // Set up the log stream process
        process = Process()
        pipe = Pipe()

        process?.launchPath = "/usr/bin/log"
        process?.arguments = [
            "stream",
            "--predicate",
            "subsystem == 'com.apple.Music' AND category == 'ampplay'",
        ]
        process?.standardOutput = pipe  // only need standard output

        // Handle log output
        // FIXME: after sleep, this might be dead
        pipe?.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let logMessage = String(data: data, encoding: .utf8),
                !logMessage.isEmpty
            {
                // Process each log line
                logMessage.split(separator: "\n").forEach {
                    self?.processLogLine($0)
                }
            }
        }

        // automatically restart process if it's dead
        process?.terminationHandler = { [weak self] process in
            self?.restartMonitoring()
        }

        // Launch the process
        do {
            try process?.run()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Unable to listen logs"
            alert.informativeText =
                "This should not happen, but I can not listen to system logs with the /usr/bin/log program. And I don't know why...."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")

            alert.runModal()

            print("Failed to launch log stream process: \(error)")
        }
    }

    func stopMonitoring() {
        // Reset the termination handler so it will not automatically restart when being terminated
        if process?.isRunning == true {
            process?.terminationHandler = nil
            process?.terminate()
        }
    }

    func restartMonitoring() {
        stopMonitoring()
        startMonitoring()
    }

    func setCurrentPlayInfo(_ url: String?, _ startAt: Double) {
        // when track changed, the current quality should be cleared
        // so, if track is skipped, the new quality will come later
        // of track is continius play, the quality info will come when last track comes to end
        // either way, the current quality is empty, so it will always trigger change

        if url != nil && url != currentPlayingItemId {
            currentPlayingItemId = url
            playingStartedAt = startAt
            // if track change and there is new quality info, set
            if qualityInfo.isValid() && currentPlayingItemId != nil {
                triggerSampleRateChange()
            }
        }
    }

    func triggerSampleRateChange() {
        // so far the playing item changed, the new format is about to change or already got from cache
        // so only check the playing item change
        // apple music high resolution need good internet speed, so when track start to play, the format info will get in seconds
        // but if it's caching, the new format comes when current track comes to end

        if qualityInfo.isValid() {
            print(
                "Requesting new format \(qualityInfo) for item \(currentPlayingItemId ?? "null")"
            )

            // must run on main thread
            DispatchQueue.main.async { [self] in
                newFormatDetected?(
                    qualityInfo.numChannels,
                    qualityInfo.bitDepth,
                    qualityInfo.sampleRate * 1000,
                    qualityInfo.asbdFormatId
                )
            }
        }
    }

    private func processLogLine(_ line: String.SubSequence) {
        /*
         The full log will be look like
        
         play> cm>> mediaFormatinfo '<private>' , songEnhanced, audioCapabilities: 0x10, 0x10, asbdFormatID = qlac, sdFormatID = alac, high res lossless, asbdNumChannels = 2, sdNumChannels = 2, sdBitDepth = 24 bit, asbdSampleRate = 96.0 kHz, is not rendering spatial audio
        
         Important thing is these log will popup when new track start to play, the current track is near ended and shuffle
         So I can not rely on this log to switch the sample rate, must switch at track start to play.
         */

        if line.contains(mediaFormatPattern) {
            if let m = line.firstMatch(of: bitDepthPattern) {
                qualityInfo.bitDepth = UInt32(m.1) ?? 0
            }

            if let m = line.firstMatch(of: sampleRatePattern) {
                qualityInfo.sampleRate = Double(m.1) ?? 0
            }

            if let m = line.firstMatch(of: numChannelsPattern) {
                qualityInfo.numChannels = UInt32(m.1) ?? 0
            }

            if let m = line.firstMatch(of: formatIdPattern) {
                qualityInfo.asbdFormatId = String(m.1)
            }

            if qualityInfo.isValid() {
                lastNewFormatAt = Date().timeIntervalSince1970

                if lastNewFormatAt - playingStartedAt < 5 {
                    triggerSampleRateChange()
                }
            }
        }
    }
}
