import AppKit

@main
@MainActor
struct LosslessMusicApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        // NSApplication.delegate is weak; keep it alive for the entire event loop.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = MusicController()
    private var statusItem: NSStatusItem?
    private var menuInfoView: MenuInfoView?
    private var statusMenu: NSMenu?
    private var isMenuOpen = false
    private let devicesMenu = NSMenu(title: String(localized: "Output Devices"))

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "Lossless Music")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Lossless Music"
        item.button?.target = self
        item.button?.action = #selector(toggleMenu(_:))
        // Act on mouse down so a closing click's mouse up cannot reopen the menu.
        item.button?.sendAction(on: .leftMouseDown)

        let menu = NSMenu()
        menu.delegate = self
        let header = NSMenuItem()
        let view = MenuInfoView()
        menuInfoView = view
        header.view = view
        menu.addItem(header)
        menu.addItem(.separator())
        let devices = NSMenuItem(title: String(localized: "Output Devices"), action: nil, keyEquivalent: "")
        devicesMenu.delegate = self
        devicesMenu.autoenablesItems = false
        devices.submenu = devicesMenu
        menu.addItem(devices)
        let quit = NSMenuItem(title: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        statusMenu = menu
        statusItem = item
        controller.start()
        updateDevicesMenu()
    }

    @objc private func toggleMenu(_ button: NSStatusBarButton) {
        guard let menu = statusMenu else { return }
        MusicDiagnostics.log("MENU_CLICK", "open=\(isMenuOpen)")
        if isMenuOpen {
            menu.cancelTracking()
            return
        }

        isMenuOpen = true
        button.highlight(true)
        defer {
            isMenuOpen = false
            button.highlight(false)
            MusicDiagnostics.log("MENU_TRACKING_END", "Menu state reset")
        }
        let location = NSPoint(x: button.bounds.minX,
                               y: button.isFlipped ? button.bounds.maxY : button.bounds.minY)
        menu.popUp(positioning: nil, at: location, in: button)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        isMenuOpen = false
        statusItem?.button?.highlight(false)
        MusicDiagnostics.log("MENU_CLOSE", "Menu closed")
    }

    private func updateDevicesMenu() {
        // Rebuild only when shown; Core Audio notifications update the model, not an open menu.
        devicesMenu.removeAllItems()
        let devices = controller.outputDevices
        if devices.isEmpty {
            let item = NSMenuItem(title: controller.outputDevicesError ?? String(localized: "No non-Bluetooth output devices available"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            devicesMenu.addItem(item)
            return
        }
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectOutputDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device
            item.state = device.isCurrent ? .on : .off
            devicesMenu.addItem(item)
        }
    }

    @objc private func selectOutputDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AudioOutputDevice else { return }
        controller.selectOutputDevice(device)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === devicesMenu {
            updateDevicesMenu()
            return
        }
        MusicDiagnostics.log("MENU_OPEN", "Refreshing menu snapshot")
        menuInfoView?.update(controller.playback, deviceName: controller.outputDeviceName, message: controller.message)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }
}
