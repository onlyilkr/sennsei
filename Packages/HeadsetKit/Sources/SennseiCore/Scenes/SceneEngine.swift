import Foundation
import HeadsetCore

public enum SceneStep: Equatable, Sendable {
    case pauseInTransparency(Bool)
    case noiseMode(NoiseMode)
    case eqPreset(String)
}

/// Headset values captured before a scene was applied. `nil` means unknown.
public struct SceneSnapshot: Equatable, Sendable {
    public var noiseMode: NoiseMode?
    public var pauseInTransparency: Bool?
    public var eqPreset: String?

    public init(noiseMode: NoiseMode? = nil, pauseInTransparency: Bool? = nil, eqPreset: String? = nil) {
        self.noiseMode = noiseMode
        self.pauseInTransparency = pauseInTransparency
        self.eqPreset = eqPreset
    }
}

public struct AutoSceneState: Equatable, Sendable {
    public var activeID: String?
    public var snapshot: SceneSnapshot?
    public var manualOverrideApp: String?

    public init() {}
}

public enum AutoDecision: Equatable, Sendable {
    case nothing
    case apply(Scene, snapshot: SceneSnapshot)
    case restore(SceneSnapshot, applied: Scene)
}

public enum SceneEngine {
    /// Fixed order: the pause setting goes first so switching to Transparency does not pause music needlessly.
    public static func steps(for scene: Scene) -> [SceneStep] {
        var steps: [SceneStep] = []
        if let pause = scene.pauseInTransparency { steps.append(.pauseInTransparency(pause)) }
        if let mode = scene.noiseMode { steps.append(.noiseMode(mode)) }
        if let eq = scene.eqPreset { steps.append(.eqPreset(eq)) }
        return steps
    }

    public static func match(frontApp: String?, in scenes: [Scene]) -> Scene? {
        guard let frontApp else { return nil }
        return scenes.first { $0.triggers.contains(.frontApp(bundleID: frontApp)) }
    }

    /// Only fields the applied scene touched, and only where the snapshot value is known.
    public static func restoreSteps(snapshot: SceneSnapshot, applied: Scene) -> [SceneStep] {
        var steps: [SceneStep] = []
        if applied.pauseInTransparency != nil, let pause = snapshot.pauseInTransparency {
            steps.append(.pauseInTransparency(pause))
        }
        if applied.noiseMode != nil, let mode = snapshot.noiseMode { steps.append(.noiseMode(mode)) }
        if applied.eqPreset != nil, let eq = snapshot.eqPreset { steps.append(.eqPreset(eq)) }
        return steps
    }

    public static func decide(
        state: AutoSceneState,
        frontApp: String?,
        scenes: [Scene],
        enabled: Bool,
        current: SceneSnapshot
    ) -> AutoDecision {
        guard enabled else { return .nothing }
        if let scene = match(frontApp: frontApp, in: scenes) {
            if state.activeID != scene.id, state.manualOverrideApp != frontApp {
                return .apply(scene, snapshot: current)
            }
            return .nothing
        }
        if let activeID = state.activeID, let snapshot = state.snapshot,
           let applied = scenes.first(where: { $0.id == activeID }) {
            return .restore(snapshot, applied: applied)
        }
        return .nothing
    }
}
