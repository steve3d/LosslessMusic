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
    var sampleRateItem = NSMenuItem()
    var selectedDeviceName = NSMenuItem()
    
    func setSelectedDeviceName(name: String) {
        let centeredParagraphStyle = NSMutableParagraphStyle()
        centeredParagraphStyle.alignment = .center
        
        selectedDeviceName.attributedTitle = NSAttributedString(string: "\(name)", attributes: [
            .paragraphStyle: centeredParagraphStyle
        ])
    }
    
    func setSampleRate(rate: Double) {
        let centeredParagraphStyle = NSMutableParagraphStyle()
        centeredParagraphStyle.alignment = .center
        
        let largerFont = NSFont.systemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize + 10)
        
        let sampleRate = "\(String(format: "%.1f", rate / 1000)) kHz"
        
        sampleRateItem.attributedTitle = NSAttributedString(string: sampleRate, attributes: [
            .font: largerFont,
            .foregroundColor: NSColor.white,
            .paragraphStyle: centeredParagraphStyle
        ])
        
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "App Icon")
        }
        
        logMonitor = LogMonitor()
        outputDevices = OutputDevices()
        
        logMonitor?.newFormatDetected = { [self] (channel: UInt32, bitDepth: UInt32, sampleRate: Double, formatID: String) in
            outputDevices?.changeFormat(channel: channel, bitDepth: bitDepth, sampleRate: sampleRate, formatID: formatID)
        }
        
        outputDevices?.onFormatChanged = { [self] asbd in
            setSampleRate(rate: asbd.mSampleRate)
        }
        
        setSampleRate(rate: outputDevices?.currentDeviceASBD.mSampleRate ?? 44100)

        let menu = NSMenu()

        let devicesSubmenu = NSMenu()
        for (key, value) in outputDevices?.devices ?? [:] {
            let menuItem = NSMenuItem(
                title: value.name,
                action: #selector(selectDevice(_:)),
                keyEquivalent: ""
            )
            menuItem.representedObject = key
            menuItem.state = (key == outputDevices?.defaultDeviceID) ? .on : .off
            devicesSubmenu.addItem(menuItem)
            
            if(outputDevices?.defaultDeviceID == key) {
                setSelectedDeviceName(name: value.name)
            }
        }
        
        menu.addItem(sampleRateItem)
        menu.addItem(selectedDeviceName)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Selected Device", action: nil, keyEquivalent: "").submenu = devicesSubmenu
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        
        statusItem?.menu = menu
        
        for item in menu.items {
            item.target = self
        }
    }
    

    @objc private func selectDevice(_ sender: NSMenuItem) {
        if let deviceID = sender.representedObject as? AudioDeviceID, let devices = outputDevices {
            
            devices.defaultDeviceID = deviceID
            
            if let submenu = sender.menu {
                for item in submenu.items {
                    item.state = (item.representedObject as? AudioDeviceID == deviceID) ? .on : .off
                    if(devices.defaultDeviceID == deviceID) {
                        setSelectedDeviceName(name: item.title)
                    }
                }
            }
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
    
    
}
