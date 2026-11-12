import Foundation
import HeadsetCore

/// Fixed, invented data for the README screenshots (`SennseiApp --render-previews`). Nothing here comes from a
/// real machine, a real headset or the user's settings, and nothing is read from or written to disk.
public enum PreviewSamples {
    /// Battery percentage shown in the panel header.
    public static let batteryPercent = 80
    /// The scene highlighted in the panel.
    public static let activeSceneID = "focus"

    /// Keyboard shortcuts drawn in the Shortcuts window, keyed by the action's `nameKey`.
    public static let shortcutLabels: [String: String] = [
        "hotkey.noiseCycle": "⌃⌥N",
        "hotkey.eqNext": "⌃⌥E",
        "scene.focus": "⌃⌥1",
        "scene.meeting": "⌃⌥2",
        "scene.travel": "⌃⌥3",
    ]

    /// Thursday 12 November 2026, 18:00 in `calendar`.
    public static func referenceNow(calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 18)) ?? Date(timeIntervalSince1970: 1_794_506_400)
    }

    private static func hours(_ h: Double, _ m: Double = 0) -> TimeInterval { h * 3600 + m * 60 }

    /// One week of listening, in the order the window shows it. Totals are the sums of the rows below,
    /// "Other" included.
    public static func insightsState(calendar: Calendar = .current, locale: Locale = .current) -> InsightsViewState {
        let now = referenceNow(calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -6, to: today) ?? today

        typealias Row = InsightsViewState.AppRow
        let apps = [
            Row(id: "com.google.Chrome", name: "Google Chrome", listening: hours(8, 20), call: hours(0, 25), isOther: false),
            Row(id: "com.apple.WebKit.GPU", name: AppDisplayNames.name(for: "com.apple.WebKit.GPU", locale: locale),
                listening: hours(5, 40), call: 0, isOther: false),
            Row(id: "com.apple.Music", name: "Music", listening: hours(4, 15), call: 0, isOther: false),
            Row(id: "com.apple.podcasts", name: "Podcasts", listening: hours(1, 30), call: 0, isOther: false),
            Row(id: "other", name: Strings.text("insights.other", locale: locale), listening: hours(0, 45), call: hours(0, 10), isOther: true),
        ]
        let totals = InsightsTotals(listening: apps.reduce(0) { $0 + $1.listening }, call: apps.reduce(0) { $0 + $1.call })

        let noise = InsightsViewState.noiseRows([
            NoiseShare(mode: .anc, seconds: hours(13, 30)),
            NoiseShare(mode: .transparency, seconds: hours(4, 10)),
            NoiseShare(mode: .off, seconds: hours(2, 20)),
        ])

        // Per-day listening / call minutes, Friday to Thursday; the sums equal the totals above.
        let dayMinutes: [(Double, Double)] = [(215, 0), (80, 0), (0, 0), (270, 15), (230, 10), (245, 5), (190, 5)]
        let days = dayMinutes.enumerated().compactMap { offset, value -> InsightsViewState.DayRow? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return InsightsViewState.DayRow(day: day, listening: value.0 * 60, call: value.1 * 60)
        }

        // Battery over the last 36 hours: two discharge cycles with a charge in between.
        let batteryHours: [(Double, Int)] = [
            (36, 92), (32, 78), (28, 60), (24, 41), (21, 24), (20, 100), (14, 91), (9, 74), (5, 58), (2, 66), (0, 80),
        ]
        let battery = batteryHours.map { InsightsViewState.BatteryPoint(time: now.addingTimeInterval(-$0.0 * 3600), percent: $0.1) }

        return InsightsViewState(
            range: .week, totals: totals, apps: apps, noise: noise, days: days, battery: battery,
            isEmpty: false, recording: true, degraded: false, unsupported: false, notes: [])
    }
}
