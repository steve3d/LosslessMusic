//
//  OutpuDevices.swift
//  LosslessMusic
//
//  Created by Steve Yin on 2025/4/24.
//

import Foundation
import CoreAudio


class OutputDevices {
    
    var devices: [AudioDeviceID: (name: String, formats: [AudioStreamBasicDescription])] = [:]
    var defaultDeviceID: AudioDeviceID = 0
    var currentDeviceASBD = AudioStreamBasicDescription()
    
    var onFormatChanged: ((AudioStreamBasicDescription) -> Void)?
    
    init() {
        updateCurrentDevice()
        
        for deviceID in getDeviceIds() {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var name: CFString = "" as CFString
            var size = UInt32(MemoryLayout<CFString>.size)

            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
            if status == noErr, isOutputDevice(deviceID), let deviceName = name as String? {
                let asbds = getSupportedOutputASBDs(for: deviceID)
                
                // only allow devices which has 24 bit depth
                let has24Bits = asbds.contains { asbd -> Bool in
                    return asbd.mBitsPerChannel == 24
                }
                
                if has24Bits {
                    devices[deviceID] = (name: deviceName, formats: asbds)
                }
            }
        }
    }

    deinit {
        
    }
    
    func changeFormat(channel: UInt32, bitDepth: UInt32, sampleRate: Double, formatID: String) {
        if let asbds = devices[defaultDeviceID]?.formats {
            
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyPhysicalFormat, // 通常获取物理格式
                mScope: kAudioObjectPropertyScopeOutput,      // 查询输出范围
                mElement: kAudioObjectPropertyElementMain     // 主要元素
            )
            var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            
            var currentAsbd = AudioStreamBasicDescription()
            var status = AudioObjectGetPropertyData(
                defaultDeviceID,
                &propertyAddress,
                0,
                nil,
                &propertySize,
                &currentAsbd
            )
            
            var newAsbdCandidate = asbds.first { i in matchFormat(asbd: i, channel: channel, bitDepth: bitDepth, sampleRate: sampleRate)}
            
            // On macos 15.4, some dac don't have 16bit anymore, so check 24-bit
            if newAsbdCandidate == nil && bitDepth == 16 {
                newAsbdCandidate = asbds.first { i in matchFormat(asbd: i, channel: channel, bitDepth: 24, sampleRate: sampleRate)}
            }
            
            // Still no suitable format found, then do nothing
            
            if status == noErr, var newAsbd = newAsbdCandidate {
                if currentAsbd.mBitsPerChannel != newAsbd.mBitsPerChannel ||
                    UInt(currentAsbd.mSampleRate) != UInt(newAsbd.mSampleRate) ||
                    currentAsbd.mChannelsPerFrame != newAsbd.mChannelsPerFrame {
                    
                    status = AudioObjectSetPropertyData(
                        defaultDeviceID,
                        &propertyAddress,
                        0,
                        nil,
                        propertySize,
                        &newAsbd
                    )
                    
                    if status == noErr {
                        print("Successfully changed format to \(newAsbd.mBitsPerChannel)bits, \(newAsbd.mSampleRate)")
                        onFormatChanged?(newAsbd)
                    } else {
                        print("Unable changed format to \(newAsbd.mBitsPerChannel)bits, \(newAsbd.mSampleRate)")
                    }
                }
            } else {
                print("Unable to find a format for \(bitDepth)bits, \(sampleRate / 1000)kHz, \(channel)-channel.")
            }
        
        }
    }
    
    private func matchFormat(asbd: AudioStreamBasicDescription, channel: UInt32, bitDepth: UInt32, sampleRate: Double) -> Bool {
        return asbd.mBitsPerChannel == bitDepth && UInt(asbd.mSampleRate) == UInt(sampleRate) && asbd.mChannelsPerFrame == channel
    }
    
    private func updateCurrentDevice() {
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultDeviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            0,
            nil,
            &defaultDeviceSize,
            &defaultDeviceID
        )
        
        if result != noErr {
            print("Error getting default output device: \(result)")
        }
        
        var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        // 修改属性地址以查询流格式
        defaultDeviceAddress.mSelector = kAudioStreamPropertyPhysicalFormat // 查询物理格式
        defaultDeviceAddress.mScope = kAudioObjectPropertyScopeOutput       // 输出作用域
        // mElement 保持不变 (kAudioObjectPropertyElementMain 或 0)

        let getASBDStatus = AudioObjectGetPropertyData(
            defaultDeviceID,          // 查询特定设备
            &defaultDeviceAddress,  // 属性地址
            0,                 // 无需限定符数据
            nil,               // 无需限定符数据
            &propertySize,     // 输入：缓冲区大小；输出：实际数据大小
            &currentDeviceASBD              // 接收 ASBD 的指针
        )
    }
    
    private func getDeviceIds() -> [AudioDeviceID] {
        var propsize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propsize) == noErr else {
            print("Unable to get audio devices.")
            return []
        }

        let count = Int(propsize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)

        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propsize, &deviceIDs) == noErr else {
            return []
        }
        
        return deviceIDs
    }
    
    private func isOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var streamsSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(deviceID, &address),
           AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &streamsSize) == noErr {
            return streamsSize > 0
        }
        return false
    }
    
    private func getSupportedOutputASBDs(for deviceID: AudioDeviceID) -> [AudioStreamBasicDescription] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var streamsSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &streamsSize) == noErr else {
            print("  (无法获取流数量)")
            return []
        }

        let streamCount = Int(streamsSize) / MemoryLayout<AudioStreamID>.size
        var streamIDs = [AudioStreamID](repeating: 0, count: streamCount)

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &streamsSize, &streamIDs) == noErr else {
            print("  (无法获取流 ID)")
            return []
        }
        
        var asbds: [AudioStreamBasicDescription] = [];

        for streamID in streamIDs {
            var formatSize: UInt32 = 0
            var formatAddress = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyAvailablePhysicalFormats,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            guard AudioObjectGetPropertyDataSize(streamID, &formatAddress, 0, nil, &formatSize) == noErr else {
                continue
            }

            let formatCount = Int(formatSize) / MemoryLayout<AudioStreamRangedDescription>.size
            var formats = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(), count: formatCount)

            guard AudioObjectGetPropertyData(streamID, &formatAddress, 0, nil, &formatSize, &formats) == noErr else {
                continue
            }

            for format in formats {
                asbds.append(format.mFormat)
            }
        }
        
        return asbds
    }
}
