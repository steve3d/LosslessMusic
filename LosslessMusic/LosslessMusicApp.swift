//
//  LosslessMusicApp.swift
//  LosslessMusic
//
//  Created by Steve Yin on 2025/4/24.
//

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
    var statusItem: NSStatusItem?
    var logMonitor: LogMonitor?
    var outputDevices: OutputDevices?

    let sampleRateMenuItem = NSMenuItem()
    let selectedDeviceMenuItem = NSMenuItem()
    let distributedCenter = DistributedNotificationCenter.default()
    private var showSampleRateInStatus = true
    private var currentSampleRate = "0 kHz"
    private var currentBitDepth = "0-bit"

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func setSelectedDeviceName(_ name: String) {
        let field = NSTextField(
            frame: NSRect(x: 0, y: 0, width: 200, height: 30)
        )
        field.isEditable = false
        field.isBezeled = false
        field.drawsBackground = false
        field.textColor = NSColor.gray

        let attributedString = NSMutableAttributedString(string: name)
        let fullRange = NSRange(location: 0, length: name.count)
        let centeredParagraphStyle = NSMutableParagraphStyle()
        centeredParagraphStyle.alignment = .center
        attributedString.addAttribute(
            .paragraphStyle,
            value: centeredParagraphStyle,
            range: fullRange
        )

        // offset 20, is it a dirty hack
        attributedString.addAttribute(
            .baselineOffset,
            value: NSFont.menuFont(ofSize: 0).pointSize,
            range: fullRange
        )
        field.attributedStringValue = attributedString

        selectedDeviceMenuItem.view = field
        selectedDeviceMenuItem.isEnabled = false

    }

    func setSampleRate(_ rate: Double, _ bit: UInt32) {
        let field = NSTextField(
            frame: NSRect(x: 0, y: 0, width: 200, height: 50)
        )
        field.isEditable = false
        field.isBezeled = false
        field.drawsBackground = false
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
            attributedString.addAttribute(
                .font,
                value: largeFont,
                range: sampleRateRange
            )
        }

        let centeredParagraphStyle = NSMutableParagraphStyle()
        centeredParagraphStyle.alignment = .center
        attributedString.addAttribute(
            .paragraphStyle,
            value: centeredParagraphStyle,
            range: fullRange
        )

        // is offset -20 a dirty hack?
        attributedString.addAttribute(
            .baselineOffset,
            value: -largeFont.pointSize,
            range: fullRange
        )

        field.attributedStringValue = attributedString

        sampleRateMenuItem.view = field
        sampleRateMenuItem.isEnabled = false

        if let button = statusItem?.button {
            updateStatusItem(
                button: button,
                line1: currentSampleRate,
                line2: currentBitDepth
            )
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )

        logMonitor = LogMonitor()
        outputDevices = OutputDevices()

        logMonitor?.newFormatDetected = {
            [self]
            (
                channel: UInt32,
                bitDepth: UInt32,
                sampleRate: Double,
                formatID: String
            ) in
            outputDevices?.changeFormat(
                channel: channel,
                bitDepth: bitDepth,
                sampleRate: sampleRate,
                formatId: formatID
            )
        }

        outputDevices?.onFormatChanged = { [self] asbd in
            setSampleRate(asbd.mSampleRate, asbd.mBitsPerChannel)
        }

        setSelectedDeviceName("Unknown")

        let menu = NSMenu()
        menu.addItem(sampleRateMenuItem)
        menu.addItem(selectedDeviceMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            withTitle: "Show Sample Rate",
            action: #selector(toggleMenuInfoDisplay(_:)),
            keyEquivalent: ""
        )
        .state = showSampleRateInStatus ? .on : .off
        menu.addItem(
            withTitle: "Selected Device",
            action: nil,
            keyEquivalent: ""
        ).submenu = createDevicesSubmenu()
        menu.addItem(withTitle: "About", action: nil, keyEquivalent: "")
            .submenu = createAboutSubmenu()
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            withTitle: "Quit",
            action: #selector(quit),
            keyEquivalent: "q"
        )

        setSampleRate(
            outputDevices?.currentDeviceASBD.mSampleRate ?? 44100,
            outputDevices?.currentDeviceASBD.mBitsPerChannel ?? 16
        )

        statusItem?.menu = menu

        for item in menu.items {
            item.target = self
        }

        // Listen to Music.app playing info change
        distributedCenter.addObserver(
            self,
            selector: #selector(handleDistributedNowPlayingInfoChanged),
            name: NSNotification.Name("com.apple.iTunes.playerInfo"),
            object: nil
        )
    }

    @objc private func handleDistributedNowPlayingInfoChanged(
        notification: Notification
    ) {
        // 分布式通知的 userInfo 字典本身就包含了播放信息
        if let userInfo = notification.userInfo {
            let state = userInfo["Player State"] as? String ?? "Unknown"
            //            userInfo.forEach { key, value in
            //                print("  - \(key): \(value)")
            //            }
            //

            if state == "Playing" {
                logMonitor?.setCurrentPlayInfo(
                    userInfo["Store URL"] as? String,
                    Date().timeIntervalSince1970
                )
            } else {
                logMonitor?.setCurrentPlayInfo(nil, 0)
            }

        }
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        if let deviceID = sender.representedObject as? AudioDeviceID,
            let devices = outputDevices
        {

            devices.defaultDeviceId = deviceID
            setSelectedDeviceName(sender.title)

            if let submenu = sender.menu {
                for item in submenu.items {
                    item.state =
                        (item.representedObject as? AudioDeviceID == deviceID)
                        ? .on : .off
                }
            }
        }
    }

    @objc private func toggleMenuInfoDisplay(_ sender: NSMenuItem) {
        showSampleRateInStatus = !showSampleRateInStatus

        sender.state = showSampleRateInStatus ? .on : .off

        if let button = statusItem?.button {
            updateStatusItem(
                button: button,
                line1: currentSampleRate,
                line2: currentBitDepth
            )
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
            menuItem.state =
                (deviceInfo.deviceId == outputDevices?.defaultDeviceId)
                ? .on : .off
            menu.addItem(menuItem)

            if outputDevices?.defaultDeviceId == deviceInfo.deviceId {
                setSelectedDeviceName(deviceInfo.name)
            }
        }

        return menu
    }

    private func createAboutSubmenu() -> NSMenu {
        let bundle = Bundle.main
        let menu = NSMenu()

        let version =
            bundle.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "Unknown"
        let build =
            bundle.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"

        menu.addItem(
            withTitle: "Version: \(version)",
            action: nil,
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: "Build: \(build)",
            action: nil,
            keyEquivalent: ""
        )

        return menu
    }

    /// 核心函数：绘制并更新图标
    /// - Parameters:
    ///   - button: The status item's button.
    ///   - line1: 第一行文字
    ///   - line2: 第二行文字
    private func updateStatusItem(
        button: NSStatusBarButton,
        line1: String,
        line2: String
    ) {
        if showSampleRateInStatus == false {
            button.image = NSImage(
                systemSymbolName: "music.note",
                accessibilityDescription: "App Icon"
            )
            return
        }

        let fullText = "\(line1)\n\(line2)"

        // 设置文本属性：字体、颜色、行距等
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineSpacing = -10  // 负值让行距更紧凑，需要微调

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),  // 等宽字体让数字对齐更好看
            .foregroundColor: NSColor.labelColor,  // 自动适应亮/暗模式
            .paragraphStyle: paragraphStyle,
        ]

        let attributedString = NSAttributedString(
            string: fullText,
            attributes: attributes
        )

        // 根据文字内容计算图片尺寸
        let textSize = attributedString.size()

        // 创建一张新的 NSImage
        let image = NSImage(size: textSize)

        // 在图片上进行绘制
        image.lockFocus()
        attributedString.draw(at: .zero)
        image.unlockFocus()

        // 关键步骤：将图片设置为模板（Template）模式
        // 系统会自动处理颜色，在亮色模式下为黑色，暗色模式下为白色
        image.isTemplate = true

        // 将绘制好的图片设置为 status item button 的图标
        button.image = image
        // 清空 title，否则文字和图片会同时显示
        button.title = ""
    }
}
