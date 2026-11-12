import Foundation
import GaiaProtocol

extension CommandCatalog {
    public static let standard = CommandCatalog(standardSpecs)
}

private let sennheiser = GaiaVendor.sennheiser
private let qualcomm = GaiaVendor.qualcomm

private func spec(_ vendor: UInt16, _ id: UInt16, _ name: String, _ access: CommandAccess,
                  _ payload: PayloadRule, firmware: FirmwareVersion? = nil, below: FirmwareVersion? = nil,
                  _ status: CommandStatus) -> CommandSpec {
    CommandSpec(vendor: vendor, id: id, name: name, access: access, payload: payload,
                minFirmware: firmware, maxFirmwareExclusive: below, status: status)
}

private let gen1From = FirmwareVersion(2, 12, 0)
private let gen2From = FirmwareVersion(3, 16, 4)

private let standardSpecs: [CommandSpec] = [
    spec(sennheiser, 0x1201, "firmwareVersion", .get, .empty, .verified),
    spec(sennheiser, 0x1206, "modelID", .get, .empty, .verified),
    spec(sennheiser, 0x0603, "batteryLevel", .get, .empty, .verified),
    spec(sennheiser, 0x0602, "chargingState", .get, .empty, .needsHardwareTest),
    spec(sennheiser, 0x0800, "codec", .get, .empty, .verified),
    spec(sennheiser, 0x081A, "sampleRate", .get, .empty, firmware: FirmwareVersion(3, 12, 0), .needsHardwareTest),
    spec(sennheiser, 0x0804, "audioMode", .get, .empty, .needsHardwareTest),
    spec(sennheiser, 0x0803, "setAudioMode", .set, .exact(2), .needsHardwareTest),
    spec(sennheiser, 0x1000, "eqConfig", .get, .empty, firmware: FirmwareVersion(3, 16, 4), .needsHardwareTest),
    spec(sennheiser, 0x1002, "eqBandGain", .get, .exact(1), firmware: FirmwareVersion(3, 16, 4), .needsHardwareTest),
    spec(sennheiser, 0x1003, "eqAllGains", .get, .exact(1), firmware: FirmwareVersion(3, 16, 4), .needsHardwareTest),
    spec(sennheiser, 0x100B, "eqBandFrequency", .get, .exact(1), firmware: FirmwareVersion(3, 16, 4), .needsHardwareTest),
    spec(sennheiser, 0x1001, "setEqBandGain", .set, .exact(2), firmware: FirmwareVersion(3, 16, 4), .needsHardwareTest),
    spec(sennheiser, 0x1009, "bassBoost", .get, .empty, firmware: FirmwareVersion(3, 16, 4), .needsHardwareTest),
    spec(sennheiser, 0x1008, "setBassBoost", .set, .exact(1), firmware: FirmwareVersion(3, 16, 4), .needsHardwareTest),
    spec(sennheiser, 0x1A05, "ancEnabled", .get, .empty, .verified),
    spec(sennheiser, 0x1A04, "setAncEnabled", .set, .exact(1), .verified),
    spec(sennheiser, 0x1805, "transparencyEnabled", .get, .empty, .verified),
    spec(sennheiser, 0x1804, "setTransparencyEnabled", .set, .exact(1), .verified),
    spec(sennheiser, 0x1801, "pauseInTransparency", .get, .empty, .verified),
    spec(sennheiser, 0x1800, "setPauseInTransparency", .set, .exact(1), .verified),
    spec(sennheiser, 0x1A01, "noiseModeTable", .get, .empty, .needsHardwareTest),
    spec(sennheiser, 0x1A03, "noiseLevel", .get, .empty, .needsHardwareTest),
    spec(sennheiser, 0x0806, "sidetone", .get, .empty, .needsHardwareTest),
    spec(sennheiser, 0x0805, "setSidetone", .set, .exact(1), .needsHardwareTest),
    spec(sennheiser, 0x0601, "autoPowerOff", .get, .exact(1), .needsHardwareTest),
    spec(sennheiser, 0x0600, "setAutoPowerOff", .set, .exact(3), .needsHardwareTest),
    spec(sennheiser, 0x0802, "voicePrompts", .get, .empty, .needsHardwareTest),
    spec(sennheiser, 0x0801, "setVoicePrompts", .set, .exact(1), .needsHardwareTest),
    spec(sennheiser, 0x1400, "pairedCount", .get, .empty, .needsHardwareTest),
    spec(sennheiser, 0x1401, "pairedEntry", .get, .exact(1), .needsHardwareTest),
    spec(sennheiser, 0x1404, "pairedStatus", .get, .exact(1), .needsHardwareTest),
    spec(sennheiser, 0x1407, "ownPairedIndex", .get, .empty, .needsHardwareTest),
    spec(sennheiser, 0x1409, "maxLinks", .get, .empty, .needsHardwareTest),
    spec(sennheiser, 0x1402, "connectPaired", .set, .exact(1), .needsHardwareTest),
    spec(sennheiser, 0x0007, "registerNotification", .set, .exact(1), .needsHardwareTest),
    // Gen1 EQ (firmware 2.12.0 ..< 3.16.4). Ids 1002/1003 are also Gen2 reads above; ranges are disjoint.
    spec(sennheiser, 0x1003, "eq1Params", .get, .lengths(18...22), firmware: gen1From, below: gen2From, .needsHardwareTest),
    spec(sennheiser, 0x1007, "eq1LevelShift", .get, .empty, firmware: gen1From, below: gen2From, .needsHardwareTest),
    spec(sennheiser, 0x1005, "eq1Knob", .get, .exact(2), firmware: gen1From, below: gen2From, .needsHardwareTest),
    spec(sennheiser, 0x1002, "eq1SetParams", .set, .exact(72), firmware: gen1From, below: gen2From, .verified),
    spec(sennheiser, 0x1006, "eq1SetLevelShift", .set, .exact(1), firmware: gen1From, below: gen2From, .verified),
    spec(sennheiser, 0x1004, "eq1SetKnob", .set, .exact(4), firmware: gen1From, below: gen2From, .verified),
    // Deny-list: destructive or link-dropping commands, never sent.
    spec(sennheiser, 0x0040, "factoryReset", .set, .lengths(0...254), .blocked),
    spec(sennheiser, 0x1403, "disconnectPaired", .set, .lengths(0...254), .blocked),
    spec(sennheiser, 0x1405, "deletePairedEntry", .set, .lengths(0...254), .blocked),
    spec(sennheiser, 0x1406, "wipePairedList", .set, .lengths(0...254), .blocked),
    spec(sennheiser, 0x0200, "firmwareUpdate", .set, .lengths(0...254), .blocked),
    spec(sennheiser, 0x0201, "firmwareUpdate", .set, .lengths(0...254), .blocked),
    spec(sennheiser, 0x0607, "offlineUntilPowerCycle", .set, .lengths(0...254), .blocked),
    spec(sennheiser, 0x0613, "resetControlLink", .set, .lengths(0...254), .blocked),
    spec(sennheiser, 0x0685, "resetControlLink", .set, .lengths(0...254), .blocked),
    spec(sennheiser, 0x1600, "touchMapWrite", .set, .lengths(0...254), .blocked),
    spec(sennheiser, 0x1604, "touchMapWrite", .set, .lengths(0...254), .blocked),
    spec(sennheiser, 0x0817, "lowLatency", .set, .lengths(0...254), .blocked),
    spec(qualcomm, 0x000D, "transportParameter", .set, .lengths(0...254), .blocked),
    spec(qualcomm, 0x0009, "dataTransfer", .set, .lengths(0...254), .blocked),
    spec(qualcomm, 0x000A, "dataTransfer", .set, .lengths(0...254), .blocked),
    spec(qualcomm, 0x0803, "panicLog", .set, .lengths(0...254), .blocked),
    spec(qualcomm, 0x0804, "panicLog", .set, .lengths(0...254), .blocked),
    spec(qualcomm, 0x0C00, "dfu", .set, .lengths(0...254), .blocked),
    spec(qualcomm, 0x0C01, "dfu", .set, .lengths(0...254), .blocked),
    spec(qualcomm, 0x0C02, "dfu", .set, .lengths(0...254), .blocked),
    spec(qualcomm, 0x0601, "voiceAssistant", .set, .lengths(0...254), .blocked),
]
