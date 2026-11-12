import Foundation
import Testing
@testable import SennseiCore

@Suite struct PreviewSampleDataTests {
    static let en = Locale(identifier: "en")
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    static var state: InsightsViewState { PreviewSamples.insightsState(calendar: calendar, locale: en) }

    @Test func valuesAreStable() {
        let s = Self.state
        #expect(s == PreviewSamples.insightsState(calendar: Self.calendar, locale: Self.en))
        #expect(s.range == .week)
        #expect(s.totals.listening == 20 * 3600 + 30 * 60)
        #expect(s.totals.call == 35 * 60)
        #expect(s.apps.map(\.name) == ["Google Chrome", "Safari & WebKit apps", "Music", "Podcasts", "Other"])
        #expect(s.noise.map(\.percent) == [67, 21, 12])
        #expect(s.days.count == 7)
        #expect(PreviewSamples.batteryPercent == 80)
    }

    @Test func totalsMatchRowsIncludingOther() {
        let s = Self.state
        #expect(s.apps.filter(\.isOther).count == 1)
        #expect(s.apps.last?.isOther == true)
        #expect(s.apps.reduce(0) { $0 + $1.listening } == s.totals.listening)
        #expect(s.apps.reduce(0) { $0 + $1.call } == s.totals.call)
        #expect(s.days.reduce(0) { $0 + $1.listening } == s.totals.listening)
        #expect(s.days.reduce(0) { $0 + $1.call } == s.totals.call)
        #expect(s.noise.reduce(0) { $0 + $1.percent } == 100)
        // Calls are small but present; durations are a few hours.
        #expect(s.totals.call > 0 && s.totals.call < s.totals.listening / 10)
        #expect(s.totals.listening > 3600 && s.totals.listening < 40 * 3600)
    }

    @Test func daysAreSevenConsecutiveDaysEndingOnTheReferenceDay() {
        let s = Self.state
        let cal = Self.calendar
        #expect(s.days.last?.day == cal.startOfDay(for: PreviewSamples.referenceNow(calendar: cal)))
        for pair in zip(s.days, s.days.dropFirst()) {
            #expect(cal.date(byAdding: .day, value: 1, to: pair.0.day) == pair.1.day)
        }
    }

    @Test func batteryLineIsOrderedAndInRange() {
        let s = Self.state
        #expect(s.battery.count > 5)
        #expect(zip(s.battery, s.battery.dropFirst()).allSatisfy { $0.time < $1.time })
        #expect(s.battery.allSatisfy { (0...100).contains($0.percent) })
        #expect(s.battery.last?.percent == PreviewSamples.batteryPercent)
    }

    @Test func containsNoPersonalData() {
        let s = Self.state
        var texts = s.apps.flatMap { [$0.id, $0.name] }
        texts += s.notes.map(\.text)
        texts += PreviewSamples.shortcutLabels.map { "\($0.key) \($0.value)" }
        for text in texts {
            #expect(!text.contains("/Users/"))
            #expect(!text.contains("@"))
            #expect(!text.contains(NSUserName()))
            #expect(!text.contains(NSHomeDirectory()))
        }
    }

    @Test func shortcutSamplesCoverEveryDefaultAction() {
        let keys = Set(PreviewSamples.shortcutLabels.keys)
        let expected = Set(["hotkey.noiseCycle", "hotkey.eqNext"]).union(Scene.defaults.map { "scene.\($0.id)" })
        #expect(keys == expected)
    }
}
