import Cocoa
import CoreAudio
import SwiftUI

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
    
    // MARK: - Properties
    var statusItem: NSStatusItem?
    var logMonitor: LogMonitor?
    var outputDevices: OutputDevices?

    private let sampleRateMenuItem = NSMenuItem()
    private let selectedDeviceMenuItem = NSMenuItem()
    
    private var showSampleRateInStatus = true
    private var currentSampleRate = "..."
    private var currentBitDepth = "..."

    // MARK: - Application Lifecycle
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        outputDevices = OutputDevices()
        logMonitor = LogMonitor()

        setupCallbacks()
        refreshUI()
    }
    
    // MARK: - Core Logic Setup
    private func setupCallbacks() {
        logMonitor?.newFormatDetected = { [weak self] channels, bitDepth, sampleRate, formatId in
            self?.outputDevices?.changeFormat(channels: channels, bitDepth: bitDepth, sampleRate: sampleRate, formatId: formatId)
        }

        outputDevices?.onFormatChanged = { [weak self] newFormat in
            // This now calls your custom UI function
            self?.setSampleRate(newFormat.asbd.mSampleRate, newFormat.asbd.mBitsPerChannel)
        }
        
        outputDevices?.onDeviceListChanged = { [weak self] in
            self?.refreshUI()
        }
    }
    
    // MARK: - UI Construction and Updates
    private func refreshUI() {
        // Rebuilds the entire menu to reflect the current state
        buildMenu()
        // Updates the status bar icon
        if let button = statusItem?.button {
            updateStatusItemIcon(button: button, line1: currentSampleRate, line2: currentBitDepth)
        }
    }
    
    private func buildMenu() {
        // This prevents the "already in another menu" exception.
        sampleRateMenuItem.menu?.removeItem(sampleRateMenuItem)
        selectedDeviceMenuItem.menu?.removeItem(selectedDeviceMenuItem)
        
        let menu = NSMenu()
        
        menu.addItem(sampleRateMenuItem)
        menu.addItem(selectedDeviceMenuItem)
        menu.addItem(NSMenuItem.separator())

        let devicesMenuItem = NSMenuItem(title: "Output Device", action: nil, keyEquivalent: "")
        devicesMenuItem.submenu = createDevicesSubmenu() // Use your helper
        menu.addItem(devicesMenuItem)

        let showRateItem = NSMenuItem(title: "Show Sample Rate", action: #selector(toggleMenuInfoDisplay(_:)), keyEquivalent: "")
        showRateItem.state = showSampleRateInStatus ? .on : .off
        menu.addItem(showRateItem)

        let aboutItem = NSMenuItem(title: "About", action: nil, keyEquivalent: "")
        aboutItem.submenu = createAboutSubmenu() // Use your helper
        menu.addItem(aboutItem)
        
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        menu.addItem(quitItem)
        
        // Set target for all actionable items
        for item in menu.items { item.target = self }
        
        // Set initial state for the custom views
        if let currentFormatASBD = getCurrentPhysicalFormat(for: outputDevices?.defaultDeviceId ?? 0) {
            setSampleRate(currentFormatASBD.mSampleRate, currentFormatASBD.mBitsPerChannel)
        }
        
        statusItem?.menu = menu
    }
    
    private func createDevicesSubmenu() -> NSMenu {
        let menu = NSMenu()
        guard let outputDevices = outputDevices else { return menu }

        for device in outputDevices.devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.representedObject = device.deviceId
            if device.deviceId == outputDevices.defaultDeviceId {
                item.state = .on
                // This now calls your custom UI function
                setSelectedDeviceName(device.name)
            }
            menu.addItem(item)
        }
        return menu
    }
    
    private func createAboutSubmenu() -> NSMenu {
        let menu = NSMenu()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "N/A"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "N/A"
        menu.addItem(withTitle: "Version: \(version) (\(build))", action: nil, keyEquivalent: "")
        return menu
    }

    // MARK: - Your Original Custom UI Functions (Restored)

    /// Your original rich-text display function for the selected device.
    func setSelectedDeviceName(_ name: String) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        field.isEditable = false; field.isBezeled = false; field.drawsBackground = false
        field.textColor = NSColor.gray
        let attributedString = NSMutableAttributedString(string: name)
        let fullRange = NSRange(location: 0, length: name.count)
        let centeredParagraphStyle = NSMutableParagraphStyle()
        centeredParagraphStyle.alignment = .center
        attributedString.addAttribute(.paragraphStyle, value: centeredParagraphStyle, range: fullRange)
        attributedString.addAttribute(.baselineOffset, value: NSFont.menuFont(ofSize: 0).pointSize, range: fullRange)
        field.attributedStringValue = attributedString
        selectedDeviceMenuItem.view = field
        selectedDeviceMenuItem.isEnabled = false
    }
    
    /// Your original rich-text display function for sample rate.
    func setSampleRate(_ rate: Double, _ bit: UInt32) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
        field.isEditable = false; field.isBezeled = false; field.drawsBackground = false
        field.textColor = NSColor.selectedMenuItemTextColor

        currentSampleRate = "\(String(format: "%.1f", rate / 1000)) kHz"
        currentBitDepth = "\(bit)-bit"
        let fullText = "\(currentSampleRate)  \(currentBitDepth)"
        let attributedString = NSMutableAttributedString(string: fullText)
        let fullRange = NSRange(location: 0, length: fullText.count)
        let menuFont = NSFont.menuFont(ofSize: 0)
        attributedString.addAttribute(.font, value: menuFont, range: fullRange)
        let largeFont = NSFont.menuFont(ofSize: menuFont.pointSize + 8)
        if let range = fullText.range(of: currentSampleRate) {
            let sampleRateRange = NSRange(range, in: fullText)
            attributedString.addAttribute(.font, value: largeFont, range: sampleRateRange)
        }
        let centeredParagraphStyle = NSMutableParagraphStyle()
        centeredParagraphStyle.alignment = .center
        attributedString.addAttribute(.paragraphStyle, value: centeredParagraphStyle, range: fullRange)
        attributedString.addAttribute(.baselineOffset, value: -largeFont.pointSize, range: fullRange)
        field.attributedStringValue = attributedString
        sampleRateMenuItem.view = field
        sampleRateMenuItem.isEnabled = false

        if let button = statusItem?.button {
            updateStatusItemIcon(button: button, line1: currentSampleRate, line2: currentBitDepth)
        }
    }
    
    /// Your original status item icon drawing function.
    private func updateStatusItemIcon(button: NSStatusBarButton, line1: String, line2: String) {
        if !showSampleRateInStatus {
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "App Icon")
            button.title = ""
            return
        }
        let fullText = "\(line1)\n\(line2)"
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineSpacing = -10
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle,
        ]
        let attributedString = NSAttributedString(string: fullText, attributes: attributes)
        let textSize = attributedString.size()
        let image = NSImage(size: textSize)
        image.lockFocus()
        attributedString.draw(at: .zero)
        image.unlockFocus()
        image.isTemplate = true
        button.image = image
        button.title = ""
    }

    // MARK: - Actions
    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let deviceID = sender.representedObject as? AudioDeviceID else { return }
        outputDevices?.setDefaultDevice(to: deviceID)
    }

    @objc private func toggleMenuInfoDisplay(_ sender: NSMenuItem) {
        showSampleRateInStatus.toggle()
        sender.state = showSampleRateInStatus ? .on : .off
        refreshUI()
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
