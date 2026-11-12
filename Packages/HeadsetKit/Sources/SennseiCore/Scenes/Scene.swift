import Foundation
import HeadsetCore

/// A named bundle of headset settings, optionally applied automatically by triggers.
/// `name` is only displayed for user scenes; the built-in defaults are shown via `Strings`.
public struct Scene: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var noiseMode: NoiseMode?
    public var pauseInTransparency: Bool?
    public var eqPreset: String?
    public var triggers: [SceneTrigger]

    public init(
        id: String,
        name: String,
        noiseMode: NoiseMode? = nil,
        pauseInTransparency: Bool? = nil,
        eqPreset: String? = nil,
        triggers: [SceneTrigger] = []
    ) {
        self.id = id
        self.name = name
        self.noiseMode = noiseMode
        self.pauseInTransparency = pauseInTransparency
        self.eqPreset = eqPreset
        self.triggers = triggers
    }

    public static let focus = Scene(id: "focus", name: "Focus", noiseMode: .anc, eqPreset: "Flat")
    public static let meeting = Scene(id: "meeting", name: "Meeting", noiseMode: .transparency, pauseInTransparency: false)
    public static let travel = Scene(id: "travel", name: "Travel", noiseMode: .anc, eqPreset: "Rock")
    public static let defaults: [Scene] = [focus, meeting, travel]

    private enum CodingKeys: String, CodingKey {
        case id, name, noiseMode, pauseInTransparency, eqPreset, triggers
    }

    private struct LossyTrigger: Decodable {
        let value: SceneTrigger?
        init(from decoder: Decoder) throws { value = try? SceneTrigger(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        // NoiseMode is declared in HeadsetCore without Codable; go through its raw value.
        noiseMode = try c.decodeIfPresent(String.self, forKey: .noiseMode).flatMap(NoiseMode.init(rawValue:))
        pauseInTransparency = try c.decodeIfPresent(Bool.self, forKey: .pauseInTransparency)
        eqPreset = try c.decodeIfPresent(String.self, forKey: .eqPreset)
        triggers = (try c.decodeIfPresent([LossyTrigger].self, forKey: .triggers) ?? []).compactMap(\.value)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(noiseMode?.rawValue, forKey: .noiseMode)
        try c.encodeIfPresent(pauseInTransparency, forKey: .pauseInTransparency)
        try c.encodeIfPresent(eqPreset, forKey: .eqPreset)
        try c.encode(triggers, forKey: .triggers)
    }
}

public enum SceneTrigger: Codable, Equatable, Sendable {
    case frontApp(bundleID: String)

    private enum CodingKeys: String, CodingKey { case kind, bundleID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "frontApp":
            self = .frontApp(bundleID: try c.decode(String.self, forKey: .bundleID))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown trigger kind \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .frontApp(let bundleID):
            try c.encode("frontApp", forKey: .kind)
            try c.encode(bundleID, forKey: .bundleID)
        }
    }
}
