import Foundation
import HeadsetCore

extension NoiseMode: Codable {}

public enum ActivityKind: String, Codable, Sendable, Equatable { case listening, call }
public enum AudioRoute: String, Codable, Sendable, Equatable { case bluetooth, usb }

/// One process that is currently sending audio to the headphones.
public struct ProcessActivity: Sendable, Equatable {
    public var bundleID: String
    public var appName: String?
    public var outputRunning: Bool
    public var inputRunning: Bool
    public var route: AudioRoute

    public init(bundleID: String, appName: String? = nil, outputRunning: Bool, inputRunning: Bool, route: AudioRoute) {
        self.bundleID = bundleID
        self.appName = appName
        self.outputRunning = outputRunning
        self.inputRunning = inputRunning
        self.route = route
    }
}

public struct InsightsSample: Sendable, Equatable {
    public var time: Date
    public var processes: [ProcessActivity]
    public var connected: Bool
    public var noiseMode: NoiseMode?
    public var battery: Int?
    public var charging: Bool?

    public init(
        time: Date, processes: [ProcessActivity] = [], connected: Bool = true,
        noiseMode: NoiseMode? = nil, battery: Int? = nil, charging: Bool? = nil
    ) {
        self.time = time
        self.processes = processes
        self.connected = connected
        self.noiseMode = noiseMode
        self.battery = battery
        self.charging = charging
    }
}

public struct ActivityInterval: Codable, Sendable, Equatable {
    public var app: String
    public var appName: String?
    public var kind: ActivityKind
    public var route: AudioRoute
    /// Noise mode at the moment the interval started.
    public var noiseMode: NoiseMode?
    public var start: Date
    public var end: Date

    public init(app: String, appName: String?, kind: ActivityKind, route: AudioRoute, noiseMode: NoiseMode?, start: Date, end: Date) {
        self.app = app
        self.appName = appName
        self.kind = kind
        self.route = route
        self.noiseMode = noiseMode
        self.start = start
        self.end = end
    }
}

public struct NoiseInterval: Codable, Sendable, Equatable {
    public var mode: NoiseMode
    public var start: Date
    public var end: Date

    public init(mode: NoiseMode, start: Date, end: Date) {
        self.mode = mode
        self.start = start
        self.end = end
    }
}

public struct BatteryReading: Codable, Sendable, Equatable {
    public var time: Date
    public var percent: Int
    public var charging: Bool?

    public init(time: Date, percent: Int, charging: Bool?) {
        self.time = time
        self.percent = percent
        self.charging = charging
    }
}

public struct RecorderOutput: Sendable, Equatable {
    public var activity: [ActivityInterval]
    public var noise: [NoiseInterval]
    public var battery: [BatteryReading]

    public init(activity: [ActivityInterval] = [], noise: [NoiseInterval] = [], battery: [BatteryReading] = []) {
        self.activity = activity
        self.noise = noise
        self.battery = battery
    }

    public var isEmpty: Bool { activity.isEmpty && noise.isEmpty && battery.isEmpty }
}
