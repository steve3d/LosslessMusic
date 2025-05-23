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
    private var newMediaFormatInfo = false
    
    // media format info for lossless only
    private let mediaFormatPattern = /play\> cm\>> mediaFormatinfo.*lossless,/
    
    private let bitDepthPattern = /sdBitDepth = (\d+)/
    private let sampleRatePattern = /asbdSampleRate = (\d+(?:\.\d+)?)/
    private let formatIdPattern = /asbdFormatID = (\w+)/
    private let numChannelsPattern = /asbdNumChannels = (\d+)/
    
    private var bitDepth: UInt32?
    private var sampleRate: Double?
    private var numChannels: UInt32?
    private var asbdFormatId: String?

    
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
            "subsystem == 'com.apple.Music' AND category == 'ampplay'"
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
            let alert = NSAlert()
            alert.messageText = "Unable to listen logs"
            alert.informativeText = "This should not happen, but I can not listen to system logs with the /usr/bin/log program. And I don't know why...."
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
    
    private func processLogLine(_ line: String.SubSequence) {
        /*
         The full log will be look like
         
         play> cm>> mediaFormatinfo '<private>' , songEnhanced, audioCapabilities: 0x10, 0x10, asbdFormatID = qlac, sdFormatID = alac, high res lossless, asbdNumChannels = 2, sdNumChannels = 2, sdBitDepth = 24 bit, asbdSampleRate = 96.0 kHz, is not rendering spatial audio
         
         Important thing is these log will popup when new track start to play, the current track is near ended and shuffle
         So I can not rely on this log to switch the sample rate, must switch at track start to play.
         */
        if line.contains(mediaFormatPattern) {
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

            newMediaFormatInfo = true
        }
        
        // normal playing to next will contain
        // play> book> '<private>' triggerCountTrackSkipOrPlay time
        
        // skip to next will contain
        // play> lease> fp status = 1, havelease 1
        if line.contains("triggerCountTrackSkipOrPlay") ||
            line.contains("fp status = 1, havelease 1") {
            
            if newMediaFormatInfo, let bitDepth, let sampleRate, let numChannels, let asbdFormatId {
                newMediaFormatInfo = false
                
                print("Requesting new media format (\(asbdFormatId)) : Channels: \(numChannels), bitDepth: \(bitDepth), sampleRate: \(sampleRate * 1000)")
                
                // must run on main thread
                DispatchQueue.main.async { [self] in
                    newFormatDetected?(numChannels, bitDepth, sampleRate * 1000, asbdFormatId)
                }
                
                self.bitDepth = nil
                self.sampleRate = nil
                self.numChannels = nil
                self.asbdFormatId = nil
            }
            
        }
    }
}
