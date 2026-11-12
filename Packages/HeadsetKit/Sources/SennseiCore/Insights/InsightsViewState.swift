import Foundation
import HeadsetCore

/// Display-only names for audio processes that are not .app bundles. Row identity and CSV keep the raw id.
public enum AppDisplayNames {
    static let keys: [String: String] = [
        "com.apple.WebKit.GPU": "insights.app.webkit",
        "com.apple.WebKit.WebContent": "insights.app.webkit",
        "com.apple.WebKit.Networking": "insights.app.webkit",
        "systemsoundserverd": "insights.app.systemSounds",
    ]

    public static func name(for id: String, locale: Locale) -> String {
        keys[id].map { Strings.text($0, locale: locale) } ?? id
    }
}

public enum InsightsRange: CaseIterable, Sendable, Equatable {
    case today, week, month

    /// Calendar days covered, today included.
    public var days: Int {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        }
    }

    public var titleKey: String {
        switch self {
        case .today: "insights.range.today"
        case .week: "insights.range.week"
        case .month: "insights.range.month"
        }
    }
}

/// Everything the Insights window shows, aggregated here so the views stay dumb. Listening and call seconds
/// are separate numbers everywhere and are never added into one total.
public struct InsightsViewState: Equatable, Sendable {
    public struct AppRow: Equatable, Sendable, Identifiable {
        /// Bundle ID, or "other" for the rolled-up remainder.
        public var id: String
        public var name: String
        public var listening: TimeInterval
        public var call: TimeInterval
        public var isOther: Bool
    }

    public struct NoiseRow: Equatable, Sendable, Identifiable {
        public var mode: NoiseMode
        public var seconds: TimeInterval
        public var percent: Int
        public var id: NoiseMode { mode }
    }

    public struct DayRow: Equatable, Sendable, Identifiable {
        public var day: Date
        public var listening: TimeInterval
        public var call: TimeInterval
        public var id: Date { day }
    }

    public struct BatteryPoint: Equatable, Sendable, Identifiable {
        public var time: Date
        public var percent: Int
        public var id: Date { time }
    }

    public static let maxAppRows = 8
    static let otherID = "other"

    public var range: InsightsRange
    public var totals: InsightsTotals
    public var apps: [AppRow]
    public var noise: [NoiseRow]
    public var days: [DayRow]
    public var battery: [BatteryPoint]
    public var isEmpty: Bool
    public var recording: Bool
    public var degraded: Bool
    public var unsupported: Bool
    /// Zero, one or two notes (unsupported is informational, degraded is a warning; empty only when nothing else applies).
    public var notes: [Note]
    public var note: String? { notes.first?.text }

    public struct Note: Equatable, Sendable {
        public var text: String
        public var isWarning: Bool
    }

    /// `unsupported` is true when the per-app audio source is unavailable (below macOS 14.2): only noise
    /// mode and battery are recorded then. Reads never create the store file.
    @MainActor
    public static func make(
        range: InsightsRange, store: InsightsStore, service: InsightsService,
        now: Date, calendar: Calendar, locale: Locale, unsupported: Bool = false
    ) async -> InsightsViewState {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(range.days - 1), to: today) ?? today
        let interval = DateInterval(start: start, end: max(now, start))

        var readFailed = false
        func read<T>(_ fallback: T, _ body: () async throws -> T) async -> T {
            do { return try await body() } catch { readFailed = true; return fallback }
        }
        let totals = await read(InsightsTotals(listening: 0, call: 0)) { try await store.totals(interval, calendar: calendar) }
        let perApp = await read([AppTotal]()) { try await store.perApp(interval, calendar: calendar) }
        let shares = await read([NoiseShare]()) { try await store.noiseShares(interval) }
        let daily = await read([DaySeconds]()) { try await store.dailySeconds(interval, calendar: calendar) }
        let readings = await read([BatteryReading]()) { try await store.batteryReadings(interval) }

        let apps = appRows(perApp, locale: locale)
        let noise = noiseRows(shares)
        let days = dayRows(daily, from: start, count: range.days, calendar: calendar)
        let battery = readings.map { BatteryPoint(time: $0.time, percent: $0.percent) }
        let empty = apps.isEmpty && noise.isEmpty && battery.isEmpty && totals.listening == 0 && totals.call == 0
        let degraded = service.degraded || readFailed

        var notes: [Note] = []
        if unsupported { notes.append(Note(text: Strings.text("insights.unsupported", locale: locale), isWarning: false)) }
        if degraded { notes.append(Note(text: Strings.text("insights.degraded", locale: locale), isWarning: true)) }
        if notes.isEmpty, empty { notes.append(Note(text: Strings.text("insights.empty", locale: locale), isWarning: false)) }

        return InsightsViewState(
            range: range, totals: totals, apps: apps, noise: noise, days: days, battery: battery,
            isEmpty: empty, recording: service.isRecording, degraded: degraded, unsupported: unsupported, notes: notes)
    }

    /// Demo mode (SENNSEI_DEMO=1): the empty, not-recording state without touching the store or the settings.
    public static func demo(range: InsightsRange, now: Date, calendar: Calendar, locale: Locale) -> InsightsViewState {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(range.days - 1), to: today) ?? today
        return InsightsViewState(
            range: range, totals: InsightsTotals(listening: 0, call: 0), apps: [], noise: [],
            days: dayRows([], from: start, count: range.days, calendar: calendar), battery: [], isEmpty: true,
            recording: false, degraded: false, unsupported: false,
            notes: [Note(text: Strings.text("insights.empty", locale: locale), isWarning: false)])
    }

    // MARK: - Aggregation

    /// Ordered by listening + call (ordering key only; both numbers stay separate), top 8, rest as "Other".
    static func appRows(_ totals: [AppTotal], locale: Locale) -> [AppRow] {
        let sorted = totals.sorted {
            let a = $0.listening + $0.call, b = $1.listening + $1.call
            return a != b ? a > b : $0.app < $1.app
        }
        var rows = sorted.prefix(maxAppRows).map {
            AppRow(id: $0.app, name: $0.appName ?? AppDisplayNames.name(for: $0.app, locale: locale), listening: $0.listening, call: $0.call, isOther: false)
        }
        let rest = sorted.dropFirst(maxAppRows)
        if !rest.isEmpty {
            rows.append(AppRow(
                id: otherID, name: Strings.text("insights.other", locale: locale),
                listening: rest.reduce(0) { $0 + $1.listening }, call: rest.reduce(0) { $0 + $1.call }, isOther: true))
        }
        return rows
    }

    /// Whole percentages that sum to exactly 100 (largest remainder; ties go to the earlier mode). Empty for a zero total.
    static func noiseRows(_ shares: [NoiseShare]) -> [NoiseRow] {
        let total = shares.reduce(0) { $0 + $1.seconds }
        guard total > 0 else { return [] }
        let exact = shares.map { $0.seconds / total * 100 }
        var floors = exact.map { Int($0.rounded(.down)) }
        let missing = 100 - floors.reduce(0, +)
        let order = exact.indices.sorted {
            let a = exact[$0] - Double(floors[$0]), b = exact[$1] - Double(floors[$1])
            return a != b ? a > b : $0 < $1
        }
        for index in order.prefix(max(0, missing)) { floors[index] += 1 }
        return zip(shares, floors).map { NoiseRow(mode: $0.mode, seconds: $0.seconds, percent: $1) }
    }

    static func dayRows(_ daily: [DaySeconds], from start: Date, count: Int, calendar: Calendar) -> [DayRow] {
        var byDay: [Date: DaySeconds] = [:]
        for entry in daily { byDay[calendar.startOfDay(for: entry.day)] = entry }
        return (0..<count).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let entry = byDay[day]
            return DayRow(day: day, listening: entry?.listening ?? 0, call: entry?.call ?? 0)
        }
    }

    // MARK: - Formatting

    /// "2 h 05 min" / "2 sa 05 dk"; 0 is "0 min", under a minute "< 1 min". Units come from the catalog.
    public static func formatDuration(_ seconds: TimeInterval, locale: Locale) -> String {
        let hourUnit = Strings.text("insights.unit.hour", locale: locale)
        let minuteUnit = Strings.text("insights.unit.minute", locale: locale)
        guard seconds.isFinite, seconds > 0 else { return "0 \(minuteUnit)" }
        let whole = Int(seconds)
        if whole < 60 { return "< 1 \(minuteUnit)" }
        let minutes = whole / 60
        if minutes < 60 { return "\(minutes) \(minuteUnit)" }
        let rest = minutes % 60
        return "\(minutes / 60) \(hourUnit) \(rest < 10 ? "0" : "")\(rest) \(minuteUnit)"
    }
}
