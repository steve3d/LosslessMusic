//
//  LogMonitor.swift
//  LosslessMusic
//
//  Created by Steve Yin on 2025/4/24.
//

import AppKit
import OSLog
import CoreAudio

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
            "--style",
            "compact" // Use compact style for simpler parsing
        ]
        process?.standardOutput = pipe // only need standard output
        
        // Handle log output
        // FIXME: after sleep, this might be dead
        pipe?.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let logMessage = String(data: data, encoding: .utf8), !logMessage.isEmpty {
                // Process each log line
                logMessage.split(separator: "\n").forEach { self?.processLogLine($0) }
            }
        }
        
        // automatically restart process if it's dead
        process?.terminationHandler = { [weak self] process in self?.restartMonitoring()}

        // Launch the process
        do {
            try process?.run()
        } catch {
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
    
    private func processLogLine(_ line: String.SubSequence) {
        var bitDepth: UInt32?
        var sampleRate: Double?
        var numChannels: UInt32?
        var asbdFormatId: String?
        
        // find lossless media format info log
        if line.contains(mediaFormatPattern) {
            bitDepth = nil
            sampleRate = nil
            numChannels = nil
            asbdFormatId = nil
            if let m = line.firstMatch(of: bitDepthPattern) {
                bitDepth = UInt32(m.1)
            }
            
            if let m = line.firstMatch(of: sampleRatePattern) {
                sampleRate = Double(m.1)
            }
            
            if let m = line.firstMatch(of: numChannelsPattern) {
                numChannels = UInt32(m.1)
            }
            
            if let m = line.firstMatch(of: formatIdPattern) {
                asbdFormatId = String(m.1)
            }

            
            if let bitDepth, let sampleRate, let numChannels, let asbdFormatId {
                print("New playing media format (\(asbdFormatId)) : nbChannels: \(numChannels), bitDepth: \(bitDepth), sampleRate: \(sampleRate * 1000)")
                
                // must run on main thread
                DispatchQueue.main.async { [self] in
                    newFormatDetected?(numChannels, bitDepth, sampleRate * 1000, asbdFormatId)
                }
            }
        }
    }
}
