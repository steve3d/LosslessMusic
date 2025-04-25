//
//  LogMonitor.swift
//  LosslessMusic
//
//  Created by Steve Yin on 2025/4/24.
//

import OSLog
import CoreAudio

class LogMonitor {
    private var process: Process?
    private var pipe: Pipe?
    private var defaultDeviceId: AudioDeviceID = 0

    
    // Callback for media start to play, use call back for extreme simple solution
    // 1. nbChannels
    // 2. bitDepth
    // 3. sampleRate
    // 4. mediaFormatId
    var newFormatDetected: ((UInt32, UInt32, Double, String) -> Void)?

    init() {
        startMonitoring()
    }

    deinit {
        // Terminate the process when the monitor is deallocated
        process?.terminate()
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
               
        // media format info for lossless only
        let mediaFormatPattern = /play\> cm\>> mediaFormatinfo.*lossless,/
        
        let bitDepthPattern = /sdBitDepth = (\d+)/
        let sampleRatePattern = /asbdSampleRate = (\d+(?:\.\d+)?)/
        let formatIdPattern = /asbdFormatID = (\w+)/
        let numChannelsPattern = /asbdNumChannels = (\d+)/
        
        
        var bitDepth: UInt32?
        var sampleRate: Double?
        var numChannels: UInt32?
        var asbdFormatId: String?

        // Handle log output
        pipe?.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let logMessage = String(data: data, encoding: .utf8), !logMessage.isEmpty {
                // Process each log line
                let lines = logMessage.split(separator: "\n")
                for line in lines {
                    // found lossless media format info log
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
                            self?.newFormatDetected?(numChannels, bitDepth, sampleRate * 1000, asbdFormatId)
                        }
                    }
                    
                }
            }
        }

        // Launch the process
        do {
            try process?.run()
        } catch {
            print("Failed to launch log stream process: \(error)")
        }
    }
}
