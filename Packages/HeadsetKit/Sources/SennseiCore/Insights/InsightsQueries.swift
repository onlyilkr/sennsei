import Foundation
import HeadsetCore

public struct AppTotal: Equatable, Sendable {
    public var app: String
    public var appName: String?
    public var listening: TimeInterval
    public var call: TimeInterval

    public init(app: String, appName: String?, listening: TimeInterval, call: TimeInterval) {
        self.app = app
        self.appName = appName
        self.listening = listening
        self.call = call
    }
}

/// Listening and call seconds are independent (one app can do both at once), so they are never summed.
public struct InsightsTotals: Equatable, Sendable {
    public var listening: TimeInterval
    public var call: TimeInterval

    public init(listening: TimeInterval, call: TimeInterval) {
        self.listening = listening
        self.call = call
    }
}

public struct NoiseShare: Equatable, Sendable {
    public var mode: NoiseMode
    public var seconds: TimeInterval

    public init(mode: NoiseMode, seconds: TimeInterval) {
        self.mode = mode
        self.seconds = seconds
    }
}

public struct DaySeconds: Equatable, Sendable {
    public var day: Date
    public var listening: TimeInterval
    public var call: TimeInterval

    public init(day: Date, listening: TimeInterval, call: TimeInterval) {
        self.day = day
        self.listening = listening
        self.call = call
    }
}

extension InsightsStore {
    /// Per-app seconds in `range`. Raw rows are clipped to the range; rolled-up daily summaries (data older
    /// than 90 days) are counted WHOLE for every day with `startOfDay(range.start) <= day < range.end`, so a
    /// range that starts or ends part-way through a rolled-up day includes that entire day. UI ranges (at most
    /// 30 days) never reach rolled-up data, so this is intentional and pinned by a test.
    public func perApp(_ range: DateInterval, calendar: Calendar = .current) throws -> [AppTotal] {
        guard let db = try openExisting(readOnly: true) else { return [] }
        var listening: [String: TimeInterval] = [:]
        var call: [String: TimeInterval] = [:]

        func add(_ app: String, _ kind: String, _ seconds: Double) {
            if kind == ActivityKind.call.rawValue { call[app, default: 0] += seconds } else { listening[app, default: 0] += seconds }
        }

        try db.query(
            """
            SELECT app, kind, SUM(MAX(0, MIN("end", ?2) - MAX(start, ?1))) FROM activity
            WHERE "end" > ?1 AND start < ?2 GROUP BY app, kind
            """,
            [.double(range.start.timeIntervalSince1970), .double(range.end.timeIntervalSince1970)]
        ) { add($0.text(0), $0.text(1), $0.double(2)) }

        // Summaries hold whole local days that were rolled out of the raw table at prune time.
        let firstDay = calendar.startOfDay(for: range.start)
        try db.query(
            "SELECT app, kind, SUM(seconds) FROM daily WHERE day >= ?1 AND day < ?2 GROUP BY app, kind",
            [.double(firstDay.timeIntervalSince1970), .double(range.end.timeIntervalSince1970)]
        ) { add($0.text(0), $0.text(1), $0.double(2)) }

        var names: [String: String] = [:]
        try db.query("SELECT app, name FROM app_names") {
            names[$0.text(0)] = $0.text(1)
        }

        let apps = Set(listening.keys).union(call.keys)
        return apps.map {
            AppTotal(app: $0, appName: names[$0], listening: listening[$0] ?? 0, call: call[$0] ?? 0)
        }.filter { $0.listening > 0 || $0.call > 0 }
        .sorted {
            let a = max($0.listening, $0.call), b = max($1.listening, $1.call)
            return a != b ? a > b : $0.app < $1.app
        }
    }

    public func totals(_ range: DateInterval, calendar: Calendar = .current) throws -> InsightsTotals {
        let apps = try perApp(range, calendar: calendar)
        return InsightsTotals(listening: apps.reduce(0) { $0 + $1.listening }, call: apps.reduce(0) { $0 + $1.call })
    }

    public func noiseShares(_ range: DateInterval) throws -> [NoiseShare] {
        guard let db = try openExisting(readOnly: true) else { return [] }
        var seconds: [NoiseMode: TimeInterval] = [:]
        try db.query(
            """
            SELECT mode, SUM(MAX(0, MIN("end", ?2) - MAX(start, ?1))) FROM noise
            WHERE "end" > ?1 AND start < ?2 GROUP BY mode
            """,
            [.double(range.start.timeIntervalSince1970), .double(range.end.timeIntervalSince1970)]
        ) {
            if let mode = NoiseMode(rawValue: $0.text(0)) { seconds[mode, default: 0] += $0.double(1) }
        }
        return NoiseMode.allCases.compactMap { mode in
            guard let s = seconds[mode], s > 0 else { return nil }
            return NoiseShare(mode: mode, seconds: s)
        }
    }

    public func dailySeconds(_ range: DateInterval, calendar: Calendar) throws -> [DaySeconds] {
        guard let db = try openExisting(readOnly: true) else { return [] }
        var listening: [Date: TimeInterval] = [:]
        var call: [Date: TimeInterval] = [:]

        func add(_ day: Date, _ kind: String, _ seconds: Double) {
            if kind == ActivityKind.call.rawValue { call[day, default: 0] += seconds } else { listening[day, default: 0] += seconds }
        }

        var raw: [(String, Double, Double)] = []
        try db.query(
            "SELECT kind, start, \"end\" FROM activity WHERE \"end\" > ?1 AND start < ?2",
            [.double(range.start.timeIntervalSince1970), .double(range.end.timeIntervalSince1970)]
        ) { raw.append(($0.text(0), $0.double(1), $0.double(2))) }
        for (kind, s, e) in raw {
            var cursor = max(Date(timeIntervalSince1970: s), range.start)
            let end = min(Date(timeIntervalSince1970: e), range.end)
            while cursor < end {
                let dayStart = calendar.startOfDay(for: cursor)
                guard let next = calendar.date(byAdding: .day, value: 1, to: dayStart), next > cursor else { break }
                let sliceEnd = min(next, end)
                add(dayStart, kind, sliceEnd.timeIntervalSince(cursor))
                cursor = sliceEnd
            }
        }

        let firstDay = calendar.startOfDay(for: range.start)
        var summaries: [(Double, String, Double)] = []
        try db.query(
            "SELECT day, kind, SUM(seconds) FROM daily WHERE day >= ?1 AND day < ?2 GROUP BY day, kind",
            [.double(firstDay.timeIntervalSince1970), .double(range.end.timeIntervalSince1970)]
        ) { summaries.append(($0.double(0), $0.text(1), $0.double(2))) }
        for (day, kind, seconds) in summaries {
            add(calendar.startOfDay(for: Date(timeIntervalSince1970: day)), kind, seconds)
        }

        return Set(listening.keys).union(call.keys).sorted().map {
            DaySeconds(day: $0, listening: listening[$0] ?? 0, call: call[$0] ?? 0)
        }
    }

    public func batteryReadings(_ range: DateInterval) throws -> [BatteryReading] {
        guard let db = try openExisting(readOnly: true) else { return [] }
        var out: [BatteryReading] = []
        try db.query(
            "SELECT time, percent, charging FROM battery WHERE time >= ?1 AND time <= ?2 ORDER BY time",
            [.double(range.start.timeIntervalSince1970), .double(range.end.timeIntervalSince1970)]
        ) {
            out.append(BatteryReading(
                time: Date(timeIntervalSince1970: $0.double(0)), percent: Int($0.int(1)),
                charging: $0.isNull(2) ? nil : $0.int(2) != 0))
        }
        return out
    }

    public func exportCSV() throws -> String {
        guard let db = try openExisting(readOnly: true) else { return InsightsCSV.render([]) }
        var rows: [ActivityInterval] = []
        try db.query("SELECT app, app_name, kind, route, noise, start, \"end\" FROM activity ORDER BY start, \"end\"") {
            guard let kind = ActivityKind(rawValue: $0.text(2)), let route = AudioRoute(rawValue: $0.text(3)) else { return }
            rows.append(ActivityInterval(
                app: $0.text(0), appName: $0.isNull(1) ? nil : $0.text(1), kind: kind, route: route,
                noiseMode: $0.isNull(4) ? nil : NoiseMode(rawValue: $0.text(4)),
                start: Date(timeIntervalSince1970: $0.double(5)), end: Date(timeIntervalSince1970: $0.double(6))))
        }
        return InsightsCSV.render(rows)
    }
}
