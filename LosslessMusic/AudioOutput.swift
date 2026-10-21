import CoreAudio
import Foundation

struct AudioOutputDevice: Equatable, Sendable {
    let id: AudioDeviceID
    let name: String
    let isCurrent: Bool
}

@MainActor
final class AudioOutput {
    var onDeviceChanged: (() -> Void)?
    private var listeners: [AudioObjectPropertySelector: AudioObjectPropertyListenerBlock] = [:]
    private(set) var devices: [AudioOutputDevice] = []
    private(set) var devicesError: String?

    var deviceName: String? {
        // Keep T nonoptional: Optional<AudioDeviceID> has the wrong size for Core Audio.
        let device: AudioDeviceID
        do {
            device = try read(AudioObjectID(kAudioObjectSystemObject), Self.defaultDeviceAddress)
        } catch {
            MusicDiagnostics.log("OUTPUT_NAME_FAILED", "Default device ID: \(error.localizedDescription)")
            return nil
        }
        guard device != kAudioObjectUnknown else { return nil }
        return name(for: device)
    }

    private func name(for device: AudioDeviceID) -> String? {
        var property = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &property, 0, nil, &size, &name)
        guard status == noErr, let name else {
            MusicDiagnostics.log("OUTPUT_NAME_FAILED", "device=\(device); status=\(status)")
            return nil
        }
        // Core Audio transfers ownership of kAudioObjectPropertyName to the caller.
        return name.takeRetainedValue() as String
    }

    func start() {
        guard listeners.isEmpty else { return }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.refreshDevices()
                    if selector == kAudioHardwarePropertyDefaultOutputDevice {
                        self.onDeviceChanged?()
                    }
                }
            }
            var property = address(selector)
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property,
                                                            .main, listener)
            if status == noErr {
                listeners[selector] = listener
            } else {
                MusicDiagnostics.log("OUTPUT_LISTENER_FAILED", "selector=\(selector); status=\(status)")
            }
        }
        refreshDevices()
    }

    func stop() {
        for (selector, listener) in listeners {
            var property = address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, .main, listener)
        }
        listeners.removeAll()
    }

    private func refreshDevices() {
        do {
            let current: AudioDeviceID = try read(AudioObjectID(kAudioObjectSystemObject), Self.defaultDeviceAddress)
            let identifiers: [AudioDeviceID] = try readArray(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices))
            var available: [AudioOutputDevice] = []
            for device in identifiers {
                do {
                    let transport: UInt32 = try read(device, address(kAudioDevicePropertyTransportType))
                    guard transport != kAudioDeviceTransportTypeBluetooth,
                          transport != kAudioDeviceTransportTypeBluetoothLE else { continue }
                    let alive: UInt32 = try read(device, address(kAudioDevicePropertyDeviceIsAlive))
                    guard alive != 0 else { continue }
                    let streams: [AudioStreamID] = try readArray(device, address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput))
                    guard !streams.isEmpty, let name = name(for: device) else { continue }
                    available.append(AudioOutputDevice(id: device, name: name, isCurrent: device == current))
                } catch {
                    // A device can disappear while the system's device list is being read.
                    MusicDiagnostics.log("OUTPUT_DEVICE_SKIPPED", "device=\(device); \(error.localizedDescription)")
                }
            }
            devices = available.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            devicesError = nil
            MusicDiagnostics.log("OUTPUT_DEVICES", "current=\(current); nonBluetoothOutputs=" + devices.map { "\($0.id):\($0.name)" }.joined(separator: "; "))
        } catch {
            devices = []
            devicesError = error.localizedDescription
            MusicDiagnostics.log("OUTPUT_DEVICES_FAILED", error.localizedDescription)
        }
    }

    func selectDevice(_ device: AudioDeviceID) throws {
        // Revalidate the snapshot because a device may have been unplugged while its menu was open.
        refreshDevices()
        guard let selected = devices.first(where: { $0.id == device }) else { throw OutputError.noDevice }
        guard !selected.isCurrent else { return }
        var requested = device
        try write(AudioObjectID(kAudioObjectSystemObject), Self.defaultDeviceAddress, &requested)
        MusicDiagnostics.log("OUTPUT_SELECT", "Requested system output: \(device) / \(selected.name)")
        refreshDevices()
        // The default-device listener re-applies the current track's format.
    }

    /// Cancellation and default-device identity are checked again before every write.
    func apply(_ target: LosslessFormat) async throws -> LosslessFormat {
        let device: AudioDeviceID = try read(AudioObjectID(kAudioObjectSystemObject), Self.defaultDeviceAddress)
        guard device != kAudioObjectUnknown else { throw OutputError.noDevice }
        let streams: [AudioStreamID] = try readArray(device, address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput))
        guard let stream = streams.first else { throw OutputError.unsupported }
        var physical: AudioStreamBasicDescription = try read(stream, address(kAudioStreamPropertyPhysicalFormat))
        let formats: [AudioStreamRangedDescription] = try readArray(stream, address(kAudioStreamPropertyAvailablePhysicalFormats))
        MusicDiagnostics.log("OUTPUT_SUPPORTED", "device=\(device) stream=\(stream) physicalModes=" + formats.map {
            "\($0.mFormat.mBitsPerChannel)-bit \($0.mSampleRateRange.mMinimum)...\($0.mSampleRateRange.mMaximum) Hz / \($0.mFormat.mChannelsPerFrame)ch"
        }.joined(separator: "; "))
        let candidates = formats.filter {
            $0.mFormat.mFormatID == kAudioFormatLinearPCM &&
            $0.mFormat.mChannelsPerFrame == physical.mChannelsPerFrame &&
            $0.mFormat.mBitsPerChannel >= target.bitDepth &&
            $0.mSampleRateRange.mMinimum <= target.sampleRate &&
            $0.mSampleRateRange.mMaximum >= target.sampleRate
        }.sorted {
            if $0.mFormat.mBitsPerChannel != $1.mFormat.mBitsPerChannel {
                return $0.mFormat.mBitsPerChannel < $1.mFormat.mBitsPerChannel
            }
            // Prefer an integer container when the device exposes both representations.
            return ($0.mFormat.mFormatFlags & kAudioFormatFlagIsFloat) <
                ($1.mFormat.mFormatFlags & kAudioFormatFlagIsFloat)
        }
        guard var chosen = candidates.first?.mFormat else { throw OutputError.unsupported }
        chosen.mSampleRate = target.sampleRate
        if chosen.mBitsPerChannel > target.bitDepth {
            MusicDiagnostics.log("OUTPUT_BIT_DEPTH", "Source \(target.bitDepth)-bit → supported output \(chosen.mBitsPerChannel)-bit")
        }

        try ensureCurrent(device)
        let rateAddress = address(kAudioDevicePropertyNominalSampleRate)
        let rate: Float64 = try read(device, rateAddress)
        MusicDiagnostics.log("OUTPUT_BEFORE", "device=\(device) stream=\(stream) nominal=\(rate) Hz physical=\(physical.mBitsPerChannel)-bit/\(physical.mSampleRate) Hz target=\(MusicDiagnostics.describe(target)) container=\(chosen.mBitsPerChannel)-bit")
        if abs(rate - target.sampleRate) > 0.5 {
            MusicDiagnostics.log("OUTPUT_SET_RATE", "device=\(device) \(rate) → \(target.sampleRate) Hz")
            var requestedRate = target.sampleRate
            try write(device, rateAddress, &requestedRate)
            try await waitForRate(device, target.sampleRate)
            MusicDiagnostics.log("OUTPUT_RATE_READY", "device=\(device) nominal=\(target.sampleRate) Hz")
        }
        try ensureCurrent(device)
        physical = try read(stream, address(kAudioStreamPropertyPhysicalFormat))
        if abs(physical.mSampleRate - chosen.mSampleRate) > 0.5 ||
            physical.mBitsPerChannel != chosen.mBitsPerChannel {
            MusicDiagnostics.log("OUTPUT_SET_PHYSICAL", "stream=\(stream) \(physical.mBitsPerChannel)-bit/\(physical.mSampleRate) Hz → \(chosen.mBitsPerChannel)-bit/\(chosen.mSampleRate) Hz")
            try write(stream, address(kAudioStreamPropertyPhysicalFormat), &chosen)
        }
        for _ in 0..<25 {
            try ensureCurrent(device)
            let actual: AudioStreamBasicDescription = try read(stream, address(kAudioStreamPropertyPhysicalFormat))
            let nominal: Float64 = try read(device, rateAddress)
            if abs(nominal - target.sampleRate) < 0.5,
               abs(actual.mSampleRate - target.sampleRate) < 0.5,
               actual.mBitsPerChannel == chosen.mBitsPerChannel {
                MusicDiagnostics.log("OUTPUT_READBACK", "device=\(device) stream=\(stream) nominal=\(nominal) Hz physical=\(actual.mBitsPerChannel)-bit/\(actual.mSampleRate) Hz verified")
                return LosslessFormat(sampleRate: actual.mSampleRate, bitDepth: actual.mBitsPerChannel)
            }
            try await Task.sleep(for: .milliseconds(80))
        }
        throw OutputError.verification
    }

    private func waitForRate(_ device: AudioDeviceID, _ rate: Double) async throws {
        for _ in 0..<25 {
            try ensureCurrent(device)
            let actual: Float64 = try read(device, address(kAudioDevicePropertyNominalSampleRate))
            if abs(actual - rate) < 0.5 { return }
            try await Task.sleep(for: .milliseconds(80))
        }
        throw OutputError.verification
    }

    private func ensureCurrent(_ device: AudioDeviceID) throws {
        try Task.checkCancellation()
        let current: AudioDeviceID = try read(AudioObjectID(kAudioObjectSystemObject), Self.defaultDeviceAddress)
        guard device == current else { throw CancellationError() }
    }

    private static var defaultDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func address(_ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func read<T>(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress) throws -> T {
        var property = property
        var size = UInt32(MemoryLayout<T>.size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { storage.deallocate() }
        let status = AudioObjectGetPropertyData(object, &property, 0, nil, &size, storage)
        guard status == noErr else { throw OutputError.coreAudio(status) }
        return storage.load(as: T.self)
    }

    private func readArray<T>(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress) throws -> [T] {
        var property = property
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size)
        guard status == noErr else { throw OutputError.coreAudio(status) }
        guard size > 0 else { return [] }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { storage.deallocate() }
        status = AudioObjectGetPropertyData(object, &property, 0, nil, &size, storage)
        guard status == noErr else { throw OutputError.coreAudio(status) }
        return Array(UnsafeBufferPointer(start: storage.assumingMemoryBound(to: T.self),
                                         count: Int(size) / MemoryLayout<T>.stride))
    }

    private func write<T>(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress, _ value: inout T) throws {
        try Task.checkCancellation()
        var property = property
        var settable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(object, &property, &settable)
        guard status == noErr else { throw OutputError.coreAudio(status) }
        guard settable.boolValue else { throw OutputError.readOnly }
        let result = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(object, &property, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
        guard result == noErr else { throw OutputError.coreAudio(result) }
    }
}

private enum OutputError: LocalizedError {
    case noDevice, unsupported, readOnly, verification, coreAudio(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noDevice: String(localized: "No output device available")
        case .unsupported: String(localized: "The output device does not support this lossless format")
        case .readOnly: String(localized: "The output device format cannot be changed")
        case .verification: String(localized: "Could not verify the output device format")
        case .coreAudio(let status): String(localized: "Could not configure the output device (\(status))", comment: "The number is a Core Audio error code.")
        }
    }
}
