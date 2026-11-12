import Foundation

/// What was read back from the headset's Gen1 equalizer.
public struct EQSnapshot: Codable, Equatable, Sendable {
    /// "major.minor.patch" of the firmware the snapshot was read from.
    public let firmware: String
    public let levelShiftX10: Int8
    public let knobY: UInt16
    public let gainResponse: [Int16]
    public let filterTypes: [Int16]
    /// Decoded band gains; nil when the bass-boost bit is unknown or the EQ was never configured.
    public let gains: [Double]?
    public let bassBoost: Bool?
    public let isUnconfigured: Bool

    public init(
        firmware: String, levelShiftX10: Int8, knobY: UInt16, gainResponse: [Int16],
        filterTypes: [Int16], gains: [Double]?, bassBoost: Bool?, isUnconfigured: Bool
    ) {
        self.firmware = firmware
        self.levelShiftX10 = levelShiftX10
        self.knobY = knobY
        self.gainResponse = gainResponse
        self.filterTypes = filterTypes
        self.gains = gains
        self.bassBoost = bassBoost
        self.isUnconfigured = isUnconfigured
    }
}

/// The headset's noise-control mode (ANC and transparency are two separate switches on the device).
public enum NoiseMode: String, Sendable, CaseIterable { case anc, transparency, off }

/// Everything the session knows about the connected headset.
public struct HeadsetState: Equatable, Sendable {
    public var profile: CapabilityProfile
    public var battery: UInt8?
    public var ancEnabled: Bool?
    public var transparencyEnabled: Bool?
    public var audioMode: UInt16?
    public var eq: EQSnapshot?
    public var charging: Bool?
    public var codec: UInt8?
    /// The headset pauses the music when Transparency starts (1801); nil = unknown / not read yet.
    public var pauseInTransparency: Bool?

    /// Derived from the two switches; nil when either is unknown. The device was observed to keep ANC
    /// on when transparency is turned on (both flags can be 1), so transparency takes precedence.
    public var noiseMode: NoiseMode? {
        guard let anc = ancEnabled, let transparency = transparencyEnabled else { return nil }
        if transparency { return .transparency }
        return anc ? .anc : .off
    }

    public init(
        profile: CapabilityProfile, battery: UInt8? = nil, ancEnabled: Bool? = nil,
        transparencyEnabled: Bool? = nil, audioMode: UInt16? = nil, eq: EQSnapshot? = nil,
        charging: Bool? = nil, codec: UInt8? = nil, pauseInTransparency: Bool? = nil
    ) {
        self.profile = profile
        self.battery = battery
        self.ancEnabled = ancEnabled
        self.transparencyEnabled = transparencyEnabled
        self.audioMode = audioMode
        self.eq = eq
        self.charging = charging
        self.codec = codec
        self.pauseInTransparency = pauseInTransparency
    }
}

public enum SessionError: Error, Equatable {
    case notConnected
    case timeout(String)
    case device(command: String, code: UInt8)
    case rejected(CatalogError)
    case readBackMismatch(String)
    case unsupported(String)
    case linkDead
    case transport(TransportError)
}
