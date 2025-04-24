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
        
//        do {
//            sdBitDepthPattern = try NSRegularExpression(pattern: #"sdBitDepth\s*=\s*(\d+)"#, options: [])
//            asbdSampleRatePattern = try NSRegularExpression(pattern: #"asbdSampleRate\s*=\s*(\d+(?:\.\d+)?)"#, options: [])
//        } catch {
//            print("Invalid regex: \(error.localizedDescription)")
//        }
        
        var newBitDepth: UInt32?
        var newSampleRate: Double?
        var newChannels: UInt32?
        var newFormatId: String?

        // Handle log output
        pipe?.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let logMessage = String(data: data, encoding: .utf8), !logMessage.isEmpty {
                // Process each log line
                let lines = logMessage.split(separator: "\n")
                for line in lines {
                    if line.contains("play> cm>> mediaFormatinfo") {
                        newBitDepth = nil
                        newSampleRate = nil
                        newChannels = nil
                        newFormatId = nil
                        for part in line.components(separatedBy: ", ") {
                            if part.starts(with: "sdBitDepth") {
                                newBitDepth = UInt32(part.components(separatedBy: " ")[2])
                            } else if part.starts(with: "asbdSampleRate") {
                                newSampleRate = Double(part.components(separatedBy: " ")[2])
                            } else if part.starts(with: "asbdNumChannels") {
                                newChannels = UInt32(part.components(separatedBy: " ")[2])
                            } else if part.starts(with: "asbdFormatID") {
                                newFormatId = part.components(separatedBy: " ")[2]
                            }
                        }
                        
                        if let bitDepth = newBitDepth, let sampleRate = newSampleRate, let channels = newChannels, let formatId = newFormatId {
                            print("New playing media format (\(formatId)) : nbChannels: \(channels), bitDepth: \(bitDepth), sample rate: \(sampleRate * 1000)")
                            self?.newFormatDetected?(channels, bitDepth, sampleRate * 1000, formatId)
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
