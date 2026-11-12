import CoreAudio
import Foundation
import Darwin

/// Reads per-process audio state from CoreAudio (read only, no permission prompts).
@available(macOS 14.2, *)
public struct CoreAudioActivitySource: AudioActivitySource {
    public let headphoneName: String

    public init(headphoneName: String) {
        self.headphoneName = headphoneName
    }

    public func snapshot() async -> [ProcessActivity] {
        let name = headphoneName
        return await Task.detached(priority: .utility) {
            AudioActivityFilter.activities(
                from: CoreAudioReader.rawProcesses(), headphoneName: name,
                resolveApp: CoreAudioReader.resolveApp
            )
        }.value
    }
}

@available(macOS 14.2, *)
enum CoreAudioReader {
    private static func address(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func objectIDs(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String  // property getters return +1 retained CFStrings
    }

    private static func transport(of device: AudioObjectID) -> Transport {
        switch uint32(device, kAudioDevicePropertyTransportType) {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        default: return .other
        }
    }

    private static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * 1024)  // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func rawProcesses() -> [RawAudioProcess] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        // Per-snapshot cache: many processes share the same few devices.
        var deviceCache: [AudioObjectID: RawAudioDevice?] = [:]
        func device(_ id: AudioObjectID) -> RawAudioDevice? {
            if let cached = deviceCache[id] { return cached }
            let value = string(id, kAudioObjectPropertyName).map { RawAudioDevice(name: $0, transport: transport(of: id)) }
            deviceCache[id] = .some(value)
            return value
        }
        return objectIDs(system, kAudioHardwarePropertyProcessObjectList).compactMap { object in
            let output = (uint32(object, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
            let input = (uint32(object, kAudioProcessPropertyIsRunningInput) ?? 0) != 0
            guard output || input else { return nil }  // idle: skip the remaining queries
            guard let pid = uint32(object, kAudioProcessPropertyPID) else { return nil }
            let pid32 = Int32(truncatingIfNeeded: pid)
            let bundleID = string(object, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 }
            // AudioHardware.h: for kAudioProcessPropertyDevices the scope selects the input or the output
            // device list. Output scope is what decides "plays to the headphones"; Global would mix in
            // input devices (a process recording from the headphone mic but playing to the speakers).
            let devices = objectIDs(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
                .compactMap(device)
            return RawAudioProcess(
                pid: pid32, bundleID: bundleID, executablePath: executablePath(pid: pid32),
                outputRunning: output, inputRunning: input, outputDevices: devices
            )
        }
    }

    static func resolveApp(_ appPath: String) -> (bundleID: String, name: String?)? {
        guard let bundle = Bundle(path: appPath), let id = bundle.bundleIdentifier else { return nil }
        let info = bundle.infoDictionary
        let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
        return (id, name)
    }
}
