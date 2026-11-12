public enum HeadsetModel: Equatable, Sendable {
    case accentum, accentumPlus, momentum4, unknown(String)

    public init(modelID: String) {
        if modelID.hasPrefix("ACPAEBT") { self = .accentumPlus }
        else if modelID.hasPrefix("ACAEBT") { self = .accentum }
        else if modelID.hasPrefix("M4AEBT") { self = .momentum4 }
        else { self = .unknown(modelID) }
    }
}

public enum EQGeneration: Sendable { case none, gen1, gen2 }

/// What a device can do, decided from its model id and firmware.
/// Unverified models (Plus, Momentum 4, unknown) are read-only.
public struct CapabilityProfile: Equatable, Sendable {
    public let model: HeadsetModel
    public let firmware: FirmwareVersion
    public let eq: EQGeneration
    public let eqParams: EQGen1Params?
    public let sidetoneMax: UInt8
    public let isWritable: Bool

    public init(modelID: String, firmware: FirmwareVersion) {
        let model = HeadsetModel(modelID: modelID)
        self.model = model
        self.firmware = firmware

        func generation(gen1From: FirmwareVersion, gen2From: FirmwareVersion) -> EQGeneration {
            if firmware >= gen2From { return .gen2 }
            if firmware >= gen1From { return .gen1 }
            return .none
        }
        let gen1Start = FirmwareVersion(2, 12, 0)
        switch model {
        case .accentum:
            eq = generation(gen1From: gen1Start, gen2From: FirmwareVersion(3, 16, 4))
            eqParams = eq == .gen1 ? .accentum : nil
            sidetoneMax = 2; isWritable = true
        case .accentumPlus:
            eq = generation(gen1From: gen1Start, gen2From: FirmwareVersion(3, 16, 4))
            eqParams = eq == .gen1 ? .accentum : nil
            sidetoneMax = 4; isWritable = false
        case .momentum4:
            eq = generation(gen1From: gen1Start, gen2From: FirmwareVersion(3, 18, 0))
            eqParams = eq == .gen1 ? .momentum4 : nil
            sidetoneMax = 4; isWritable = false
        case .unknown:
            eq = .none; eqParams = nil; sidetoneMax = 0; isWritable = false
        }
    }

    public static func == (a: CapabilityProfile, b: CapabilityProfile) -> Bool {
        a.model == b.model && a.firmware == b.firmware && a.eq == b.eq
            && a.sidetoneMax == b.sidetoneMax && a.isWritable == b.isWritable
    }
}
