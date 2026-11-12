import Foundation
import HeadsetCore

/// Turns a stream of samples into activity, noise and battery records. A pure value type: time comes only
/// from `sample.time`, never from the system clock.
///
/// Design notes:
/// - Listening and call are independent keys `(bundleID, kind)`. One app can have both open at once, so their
///   intervals may overlap for a few seconds (e.g. a quick call-to-listening flicker); consumers such as the
///   aggregation layer decide how to treat that.
/// - `mergeGap` and `2 * tick` are independent: a sample gap over `2 * tick` closes everything regardless of
///   `mergeGap`, so the effective cap on a merged gap is `min(mergeGap, 2 * tick)`.
/// - After a backward clock jump, restarted intervals begin no earlier than the end already emitted for that
///   stream (the watermark). Audio sampled before the new clock passes the watermark is therefore lost; that
///   trades a little data for never emitting overlapping or negative intervals.
public struct InsightsRecorder: Sendable {
    private struct Key: Hashable {
        var app: String
        var kind: ActivityKind
    }

    private struct OpenActivity {
        var appName: String?
        var route: AudioRoute
        var noiseMode: NoiseMode?
        var start: Date
        var lastSeen: Date
    }

    private struct OpenNoise {
        var mode: NoiseMode
        var start: Date
        var lastSeen: Date
    }

    public let tick: TimeInterval
    public let mergeGap: TimeInterval
    public let batteryEvery: TimeInterval
    public var excluded: Set<String>
    private let calendar: Calendar

    private var lastTime: Date?
    private var openActivity: [Key: OpenActivity] = [:]
    private var openNoise: OpenNoise?
    private var lastBattery: (time: Date, percent: Int)?
    // Latest end emitted per stream: a restarted interval never begins before it (no overlaps after a clock jump).
    private var activityMark: [Key: Date] = [:]
    private var noiseMark: Date?

    public init(
        tick: TimeInterval = 5, mergeGap: TimeInterval = 10, batteryEvery: TimeInterval = 600,
        calendar: Calendar = .current, excluded: Set<String> = []
    ) {
        self.tick = tick
        self.mergeGap = mergeGap
        self.batteryEvery = batteryEvery
        self.calendar = calendar
        self.excluded = excluded
    }

    public mutating func ingest(_ sample: InsightsSample) -> RecorderOutput {
        var out = RecorderOutput()
        let time = sample.time

        if let prev = lastTime, time < prev || time.timeIntervalSince(prev) > 2 * tick {
            closeAll(into: &out)
            lastBattery = nil
        }
        lastTime = time

        guard sample.connected else {
            closeAll(into: &out)
            lastBattery = nil
            return sorted(out)
        }

        // Activity
        var present: [Key: ProcessActivity] = [:]
        for process in sample.processes where !excluded.contains(process.bundleID) {
            let kind: ActivityKind
            if process.outputRunning && process.inputRunning { kind = .call }
            else if process.outputRunning { kind = .listening }
            else { continue }
            let key = Key(app: process.bundleID, kind: kind)
            if let existing = present[key] {
                if existing.appName == nil, process.appName != nil { present[key]?.appName = process.appName }
            } else {
                present[key] = process
            }
        }
        for (key, open) in openActivity where time.timeIntervalSince(open.lastSeen) > mergeGap {
            closeActivity(key, at: open.lastSeen.addingTimeInterval(tick), into: &out)
        }
        for (key, process) in present {
            if var open = openActivity[key] {
                open.lastSeen = time
                if open.appName == nil { open.appName = process.appName }
                openActivity[key] = open
            } else {
                let start = max(time, activityMark[key] ?? time)
                openActivity[key] = OpenActivity(
                    appName: process.appName, route: process.route, noiseMode: sample.noiseMode,
                    start: start, lastSeen: time)
            }
        }

        // Noise
        if let mode = sample.noiseMode {
            if var open = openNoise, open.mode == mode {
                open.lastSeen = time
                openNoise = open
            } else {
                closeNoise(at: min(time, openNoise.map { $0.lastSeen.addingTimeInterval(tick) } ?? time), into: &out)
                openNoise = OpenNoise(mode: mode, start: max(time, noiseMark ?? time), lastSeen: time)
            }
        } else if let open = openNoise {
            closeNoise(at: min(time, open.lastSeen.addingTimeInterval(tick)), into: &out)
        }

        // Battery
        if let percent = sample.battery {
            let due = lastBattery.map { $0.percent != percent || time.timeIntervalSince($0.time) >= batteryEvery } ?? true
            if due {
                out.battery.append(BatteryReading(time: time, percent: percent, charging: sample.charging))
                lastBattery = (time, percent)
            }
        }
        return sorted(out)
    }

    public mutating func flush() -> RecorderOutput {
        var out = RecorderOutput()
        closeAll(into: &out)
        lastTime = nil
        lastBattery = nil
        return sorted(out)
    }

    // MARK: - Closing

    private mutating func closeAll(into out: inout RecorderOutput) {
        for key in Array(openActivity.keys) {
            if let open = openActivity[key] { closeActivity(key, at: open.lastSeen.addingTimeInterval(tick), into: &out) }
        }
        if let open = openNoise { closeNoise(at: open.lastSeen.addingTimeInterval(tick), into: &out) }
    }

    private mutating func closeActivity(_ key: Key, at end: Date, into out: inout RecorderOutput) {
        guard let open = openActivity.removeValue(forKey: key) else { return }
        guard end > open.start else { return }
        activityMark[key] = max(activityMark[key] ?? end, end)
        for (start, stop) in daySlices(open.start, end) {
            out.activity.append(ActivityInterval(
                app: key.app, appName: open.appName, kind: key.kind, route: open.route,
                noiseMode: open.noiseMode, start: start, end: stop))
        }
    }

    private mutating func closeNoise(at end: Date, into out: inout RecorderOutput) {
        guard let open = openNoise else { return }
        openNoise = nil
        guard end > open.start else { return }
        noiseMark = max(noiseMark ?? end, end)
        for (start, stop) in daySlices(open.start, end) {
            out.noise.append(NoiseInterval(mode: open.mode, start: start, end: stop))
        }
    }

    /// Splits [start, end) at local midnights; every slice has positive length.
    private func daySlices(_ start: Date, _ end: Date) -> [(Date, Date)] {
        var slices: [(Date, Date)] = []
        var cursor = start
        while cursor < end {
            let dayStart = calendar.startOfDay(for: cursor)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart), nextDay > cursor else {
                slices.append((cursor, end)); break
            }
            let stop = min(end, nextDay)
            slices.append((cursor, stop))
            cursor = stop
        }
        return slices
    }

    private func sorted(_ out: RecorderOutput) -> RecorderOutput {
        var result = out
        result.activity.sort { ($0.start, $0.app, $0.kind.rawValue) < ($1.start, $1.app, $1.kind.rawValue) }
        return result
    }
}
