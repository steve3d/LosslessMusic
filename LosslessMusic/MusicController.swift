import AppKit
import Combine

@MainActor
final class MusicController: ObservableObject {
    @Published private(set) var playback = MusicPlayback()
    @Published private(set) var message: String? = String(localized: "Loading…")
    @Published private(set) var appliedFormat: LosslessFormat?

    var outputDeviceName: String? { output.deviceName }
    var outputDevices: [AudioOutputDevice] { output.devices }
    var outputDevicesError: String? { output.devicesError }

    func selectOutputDevice(_ device: AudioOutputDevice) {
        do {
            try output.selectDevice(device.id)
        } catch {
            message = error.localizedDescription
            MusicDiagnostics.log("OUTPUT_SELECT_FAILED", "device=\(device.id); \(error)")
        }
    }

    private var tracker = MusicLogTracker()
    private let monitor = MusicLogMonitor()
    private let output = AudioOutput()
    private var ready = false
    private var switchTask: Task<Void, Never>?
    private var lastRequest: MusicPlayback?
    private var observers: [NSObjectProtocol] = []
    private var musicPID: Int32?

    func start() {
        MusicDiagnostics.log("APP_START", "Menu-bar controller starting")
        monitor.onEntry = { [weak self] entry, historical in
            guard let self, entry.processID == self.musicPID else { return }
            self.tracker.consume(entry, historical: historical)
            if self.ready { self.refresh() }
        }
        monitor.onReady = { [weak self] entries in
            guard let self else { return }
            self.tracker.restoreStartupState(from: entries)
            MusicDiagnostics.log("READY", "15m history complete; state=\(self.tracker.playback.state) item=\(self.tracker.playback.item ?? "nil") format=\(MusicDiagnostics.describe(self.tracker.playback.format))")
            self.ready = true
            self.message = nil
            self.refresh()
        }
        monitor.onError = { [weak self] error in
            MusicDiagnostics.log("ERROR", error)
            self?.switchTask?.cancel()
            self?.monitor.stop()
            self?.ready = false
            self?.playback.state = .unknown
            self?.appliedFormat = nil
            self?.message = error
        }
        output.onDeviceChanged = { [weak self] in
            MusicDiagnostics.log("OUTPUT_CHANGED", "Default output device changed; cancel/re-evaluate current request")
            self?.lastRequest = nil
            self?.appliedFormat = nil
            self?.refresh()
        }
        output.start()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateMusicProcess() }
            })
        }
        updateMusicProcess()
    }

    func stop() {
        MusicDiagnostics.log("APP_STOP", "Stopping log monitor and pending device operation")
        switchTask?.cancel()
        monitor.stop()
        output.stop()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }

    private func updateMusicProcess() {
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
            .first(where: { !$0.isTerminated })?.processIdentifier
        guard pid != musicPID || (pid == nil && playback.state != .stopped) else { return }
        MusicDiagnostics.log("MUSIC_PROCESS", "pid=\(musicPID.map(String.init) ?? "none") → \(pid.map(String.init) ?? "none")")
        musicPID = pid
        switchTask?.cancel()
        monitor.stop()
        tracker.reset()
        playback = tracker.playback
        ready = false
        lastRequest = nil
        appliedFormat = nil
        guard let pid else {
            playback.state = .stopped
            message = String(localized: "Not running")
            return
        }
        message = String(localized: "Loading…")
        monitor.start(processID: pid)
    }

    private func refresh() {
        playback = tracker.playback
        guard ready else { return }
        guard playback.isPlaying, let format = playback.format else {
            switchTask?.cancel()
            lastRequest = nil
            appliedFormat = nil
            message = nil
            return
        }
        guard playback != lastRequest else { return }
        switchTask?.cancel()
        let request = playback
        lastRequest = request
        MusicDiagnostics.log("SWITCH_REQUEST", "item=\(request.item ?? "nil") revision=\(request.revision) target=\(MusicDiagnostics.describe(format))")
        message = String(localized: "Switching…")
        switchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let applied = try await self.output.apply(format)
                try Task.checkCancellation()
                guard self.playback == request else { return }
                MusicDiagnostics.log("SWITCH_VERIFIED", "item=\(request.item ?? "nil") revision=\(request.revision) actual=\(MusicDiagnostics.describe(applied))")
                self.appliedFormat = applied
                self.message = nil
            } catch is CancellationError {
                MusicDiagnostics.log("SWITCH_CANCELLED", "item=\(request.item ?? "nil") revision=\(request.revision)")
                // A new item, pause, or output device now owns the pending work.
            } catch {
                guard !Task.isCancelled, self.playback == request else { return }
                MusicDiagnostics.log("SWITCH_FAILED", "item=\(request.item ?? "nil") revision=\(request.revision) error=\(error)")
                self.message = error.localizedDescription
            }
        }
    }
}
