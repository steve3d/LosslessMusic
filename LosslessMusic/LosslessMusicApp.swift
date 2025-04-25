//
//  LosslessMusicApp.swift
//  LosslessMusic
//
//  Created by Steve Yin on 2025/4/24.
//

import SwiftUI
import CoreAudio

@main
struct LosslessMusicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var logMonitor: LogMonitor?
    var outputDevices: OutputDevices?
    
    let sampleRateMenuItem = NSMenuItem()
    let selectedDeviceMenuItem = NSMenuItem()
    
    func setSelectedDeviceName(name: String) {
        // NSTextField need and it's attributedString can only be create/set on main thread
        // So I don't know how to use NSTextField to make the string perfectly centered horizontally
        let attributedString = NSMutableAttributedString(string: name)
        let fullRange = NSRange(location: 0, length: name.count)
        let centeredParagraphStyle = NSMutableParagraphStyle()
        centeredParagraphStyle.alignment = .center
        attributedString.addAttribute(.paragraphStyle, value: centeredParagraphStyle, range: fullRange)
        
        // offset 20, is it a dirty hack
        attributedString.addAttribute(.baselineOffset, value: 20, range: fullRange)
                        
        selectedDeviceMenuItem.attributedTitle = attributedString
        selectedDeviceMenuItem.isEnabled = false
    }
    
    func setSampleRate(_ rate: Double, _ bit: UInt32) {
        // same as setSelectedDeviceName
        let sampleRate = "\(String(format: "%.1f", rate / 1000)) kHz"
        let fullText = "\(sampleRate)  \(bit)bits"
        let attributedString = NSMutableAttributedString(string: fullText)
        let fullRange = NSRange(location: 0, length: fullText.count)

        
        let defaultFont = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        attributedString.addAttribute(.font, value: defaultFont, range: fullRange)
        
        let largeFont = NSFont.menuFont(ofSize: 20)
        if let range = fullText.range(of: sampleRate) {
            let sampleRateRange = NSRange(range, in: fullText)
            attributedString.addAttribute(.font, value: largeFont, range: sampleRateRange)
        }
        
        let centeredParagraphStyle = NSMutableParagraphStyle()
        centeredParagraphStyle.alignment = .center
        attributedString.addAttribute(.paragraphStyle, value: centeredParagraphStyle, range: fullRange)
        
        // is offset -20 a dirty hack?
        attributedString.addAttribute(.baselineOffset, value: -20.0, range: fullRange)
        
        
        sampleRateMenuItem.attributedTitle = attributedString
        sampleRateMenuItem.isEnabled = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "App Icon")
        }
        
        logMonitor = LogMonitor()
        outputDevices = OutputDevices()
        
        logMonitor?.newFormatDetected = { [self] (channel: UInt32, bitDepth: UInt32, sampleRate: Double, formatID: String) in
            outputDevices?.changeFormat(channel: channel, bitDepth: bitDepth, sampleRate: sampleRate, formatId: formatID)
        }
        
        outputDevices?.onFormatChanged = { [self] asbd in
            setSampleRate(asbd.mSampleRate, asbd.mBitsPerChannel)
        }
        
        setSampleRate(outputDevices?.currentDeviceASBD.mSampleRate ?? 44100, outputDevices?.currentDeviceASBD.mBitsPerChannel ?? 16)

        let menu = NSMenu()
        menu.addItem(sampleRateMenuItem)
        menu.addItem(selectedDeviceMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Selected Device", action: nil, keyEquivalent: "").submenu = createDevicesSubmenu()
        menu.addItem(withTitle: "About", action: nil, keyEquivalent: "").submenu = createAboutSubmenu()
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        
        
        statusItem?.menu = menu
        
        for item in menu.items {
            item.target = self
        }
    }
    

    @objc private func selectDevice(_ sender: NSMenuItem) {
        if let deviceID = sender.representedObject as? AudioDeviceID, let devices = outputDevices {
            
            devices.defaultDeviceId = deviceID
            
            if let submenu = sender.menu {
                for item in submenu.items {
                    item.state = (item.representedObject as? AudioDeviceID == deviceID) ? .on : .off
                    if(devices.defaultDeviceId == deviceID) {
                        setSelectedDeviceName(name: item.title)
                    }
                }
            }
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
    
    private func createDevicesSubmenu() -> NSMenu {
        let menu = NSMenu()
        for deviceInfo in outputDevices?.devices ?? [] {
            let menuItem = NSMenuItem(
                title: deviceInfo.name,
                action: #selector(selectDevice(_:)),
                keyEquivalent: ""
            )
            menuItem.representedObject = deviceInfo.deviceId
            menuItem.state = (deviceInfo.deviceId == outputDevices?.defaultDeviceId) ? .on : .off
            menu.addItem(menuItem)
            
            if(outputDevices?.defaultDeviceId == deviceInfo.deviceId) {
                setSelectedDeviceName(name: deviceInfo.name)
            }
        }
        
        return menu
    }
    
    private func createAboutSubmenu() -> NSMenu {
        let bundle = Bundle.main
        let menu = NSMenu()
        
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        
        menu.addItem(withTitle: "Version: \(version)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Build: \(build)", action: nil, keyEquivalent: "")
        
        return menu
    }
}
