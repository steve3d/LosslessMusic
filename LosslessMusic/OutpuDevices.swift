import Foundation
import CoreAudio
import AudioToolbox

// MARK: - AudioFormat Wrapper Struct (Safe Conformance)
/// 一个包装器结构体，用于安全地为 AudioStreamBasicDescription 提供 Equatable 和 CustomStringConvertible 功能。
struct AudioFormat: Equatable, CustomStringConvertible {
    let asbd: AudioStreamBasicDescription

    static func == (lhs: AudioFormat, rhs: AudioFormat) -> Bool {
        let lhsAsbd = lhs.asbd
        let rhsAsbd = rhs.asbd
        return lhsAsbd.mSampleRate == rhsAsbd.mSampleRate &&
               lhsAsbd.mBitsPerChannel == rhsAsbd.mBitsPerChannel &&
               lhsAsbd.mChannelsPerFrame == rhsAsbd.mChannelsPerFrame &&
               lhsAsbd.mFormatID == rhsAsbd.mFormatID
    }

    var description: String {
        return "\(asbd.mBitsPerChannel)bit / \(asbd.mSampleRate / 1000)kHz / \(asbd.mChannelsPerFrame)ch"
    }
}

// MARK: - OutputDevices Class
class OutputDevices {
    
    var devices: [(deviceId: AudioDeviceID, name: String, formats: [AudioFormat])] = []
    var defaultDeviceId: AudioDeviceID = 0
    
    var onFormatChanged: ((AudioFormat) -> Void)?
    var onDeviceListChanged: (() -> Void)?

    init() {
        refreshDeviceList()
        setupAudioDeviceListeners()
    }

    deinit {
        removeAudioDeviceListeners()
    }

    func changeFormat(channels: UInt32, bitDepth: UInt32, sampleRate: Double, formatId: String) {
        guard let device = devices.first(where: { $0.deviceId == defaultDeviceId }) else { return }
        guard let currentAsbd = getCurrentPhysicalFormat(for: defaultDeviceId) else { return }
        let currentFormat = AudioFormat(asbd: currentAsbd)
        
        var targetFormat = findMatchingFormat(in: device.formats, channels: channels, bitDepth: bitDepth, sampleRate: sampleRate)
        if targetFormat == nil && bitDepth == 16 {
            print("Could not find a 16-bit format. Attempting to fall back to 24-bit...")
            targetFormat = findMatchingFormat(in: device.formats, channels: channels, bitDepth: 24, sampleRate: sampleRate)
        }

        guard let newFormat = targetFormat else {
            print("Unable to find a suitable format for \(bitDepth)bit, \(sampleRate / 1000)kHz, \(channels)-channel.")
            return
        }
        
        if newFormat == currentFormat {
            print("Format is already set to \(currentFormat). No change needed.")
            return
        }
        
        var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyPhysicalFormat, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var mutableAsbd = newFormat.asbd
        let status = AudioObjectSetPropertyData(defaultDeviceId, &propertyAddress, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &mutableAsbd)

        if status == noErr {
            print("✅ Successfully changed format from \(currentFormat) to \(newFormat)")
            onFormatChanged?(newFormat)
        } else {
            print("❌ Error changing format to \(newFormat). OSStatus: \(status)")
        }
    }
    
    /// 请求系统将默认输出设备更改为指定的设备ID
    func setDefaultDevice(to deviceID: AudioDeviceID) {
        var newDeviceID = deviceID
        let propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, propertySize, &newDeviceID)
        if status != noErr {
            print("Error setting default output device to \(deviceID). OSStatus: \(status)")
        }
    }
    
    func refreshDeviceList() {
        print("Refreshing audio device list...")
        self.defaultDeviceId = getDefaultOutputDeviceID()
        var newDeviceList: [(deviceId: AudioDeviceID, name: String, formats: [AudioFormat])] = []
        
        for deviceID in getAllDeviceIDs() {
            guard isOutputDevice(deviceID), let deviceName = getDeviceName(deviceID) else { continue }
            let formats = getSupportedOutputASBDs(for: deviceID).map { AudioFormat(asbd: $0) }
            if formats.contains(where: { $0.asbd.mBitsPerChannel >= 24 }) {
                newDeviceList.append((deviceId: deviceID, name: deviceName, formats: formats))
            }
        }
        
        self.devices = newDeviceList
        onDeviceListChanged?()
        print("Device list refreshed. Default device is '\(getDeviceName(defaultDeviceId) ?? "Unknown")' (\(defaultDeviceId)).")
    }

    private func findMatchingFormat(in formats: [AudioFormat], channels: UInt32, bitDepth: UInt32, sampleRate: Double) -> AudioFormat? {
        return formats.first { format in
            let asbd = format.asbd
            return asbd.mChannelsPerFrame == channels &&
                   asbd.mBitsPerChannel == bitDepth &&
                   UInt(asbd.mSampleRate) == UInt(sampleRate)
        }
    }
    
    private func setupAudioDeviceListeners() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, audioDevicePropertyListener, Unmanaged.passUnretained(self).toOpaque())
        address.mSelector = kAudioHardwarePropertyDevices
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, audioDevicePropertyListener, Unmanaged.passUnretained(self).toOpaque())
    }

    private func removeAudioDeviceListeners() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, audioDevicePropertyListener, Unmanaged.passUnretained(self).toOpaque())
        address.mSelector = kAudioHardwarePropertyDevices
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, audioDevicePropertyListener, Unmanaged.passUnretained(self).toOpaque())
    }
}

private let audioDevicePropertyListener: AudioObjectPropertyListenerProc = { _, _, _, clientData in
    guard let clientData = clientData else { return noErr }
    let outputDevices = Unmanaged<OutputDevices>.fromOpaque(clientData).takeUnretainedValue()
    DispatchQueue.main.async {
        outputDevices.refreshDeviceList()
    }
    return noErr
}

// MARK: - Core Audio Wrapper Functions
private func getDefaultOutputDeviceID() -> AudioDeviceID {
    var deviceID: AudioDeviceID = 0
    var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &deviceID)
    return deviceID
}

func getCurrentPhysicalFormat(for deviceID: AudioDeviceID) -> AudioStreamBasicDescription? {
    var asbd = AudioStreamBasicDescription()
    var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyPhysicalFormat, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &asbd)
    return status == noErr ? asbd : nil
}

private func getAllDeviceIDs() -> [AudioDeviceID] {
    var propertySize: UInt32 = 0
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize) == noErr else { return [] }
    let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &deviceIDs) == noErr else { return [] }
    return deviceIDs
}

private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var name: CFString = "" as CFString
    var propertySize = UInt32(MemoryLayout<CFString>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &name)
    return status == noErr ? (name as String) : nil
}

private func isOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
    var propertySize: UInt32 = 0
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(deviceID, &address), AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize) == noErr else { return false }
    return propertySize > 0
}

private func getSupportedOutputASBDs(for deviceID: AudioDeviceID) -> [AudioStreamBasicDescription] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyAvailablePhysicalFormats, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var streamAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var streamID: AudioStreamID = 0
    var streamIDSize = UInt32(MemoryLayout<AudioStreamID>.size)
    guard AudioObjectGetPropertyData(deviceID, &streamAddress, 0, nil, &streamIDSize, &streamID) == noErr else { return [] }
    var propertySize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(streamID, &address, 0, nil, &propertySize) == noErr else { return [] }
    let formatCount = Int(propertySize) / MemoryLayout<AudioStreamRangedDescription>.size
    var formatRanges = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(), count: formatCount)
    guard AudioObjectGetPropertyData(streamID, &address, 0, nil, &propertySize, &formatRanges) == noErr else { return [] }
    return formatRanges.map { $0.mFormat }
}
