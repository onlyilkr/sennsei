import Foundation
import HeadsetCore
import Testing
@testable import SennseiCore

private struct IdleSource: AudioActivitySource {
    func snapshot() async -> [ProcessActivity] { [] }
}

@MainActor
@Suite struct InsightsViewStateTests {
    static let en = Locale(identifier: "en"), tr = Locale(identifier: "tr")
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    /// Noon UTC on the day of 1_800_000_000.
    static let now = Date(timeIntervalSince1970: TimeInterval(1_800_000_000 - (1_800_000_000 % 86_400) + 12 * 3600))

    static func fixture(
        recording: Bool = true
    ) -> (store: InsightsStore, service: InsightsService, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("insights-vs-\(UUID().uuidString)", isDirectory: true)
        let store = InsightsStore(url: dir.appendingPathComponent("db/insights.sqlite"))
        let suite = "insights-vs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(recording, forKey: InsightsService.recordingKey)
        let service = InsightsService(
            store: store, source: IdleSource(),
            headset: { HeadsetInsightsSnapshot(connected: false, noiseMode: nil, battery: nil, charging: nil) },
            settings: defaults)
        return (store, service, { try? FileManager.default.removeItem(at: dir); defaults.removePersistentDomain(forName: suite) })
    }

    static func act(_ app: String, _ kind: ActivityKind = .listening, hoursAgo: Double, seconds: TimeInterval, mode: NoiseMode? = .anc) -> ActivityInterval {
        let start = now.addingTimeInterval(-hoursAgo * 3600)
        return ActivityInterval(app: app, appName: app.uppercased(), kind: kind, route: .bluetooth, noiseMode: mode, start: start, end: start.addingTimeInterval(seconds))
    }

    static func make(_ range: InsightsRange, _ f: (store: InsightsStore, service: InsightsService, cleanup: () -> Void),
                     unsupported: Bool = false, locale: Locale = en) async -> InsightsViewState {
        await InsightsViewState.make(range: range, store: f.store, service: f.service, now: now, calendar: calendar, locale: locale, unsupported: unsupported)
    }

    @Test func emptyStoreIsEmptyAndHasAnExplanatoryNote() async {
        let f = Self.fixture(); defer { f.cleanup() }
        let s = await Self.make(.today, f)
        #expect(s.isEmpty && s.recording && !s.degraded && !s.unsupported)
        #expect(s.totals == InsightsTotals(listening: 0, call: 0))
        #expect(s.note == Strings.text("insights.empty", locale: Self.en))
        #expect(!FileManager.default.fileExists(atPath: await f.store.url.path))   // reading never creates the file
    }

    @Test func recordingOffIsReflected() async {
        let f = Self.fixture(recording: false); defer { f.cleanup() }
        #expect(await Self.make(.today, f).recording == false)
    }

    @Test func unsupportedIsReflectedWithItsNote() async {
        let f = Self.fixture(); defer { f.cleanup() }
        let s = await Self.make(.today, f, unsupported: true)
        #expect(s.unsupported)
        #expect(s.note == Strings.text("insights.unsupported", locale: Self.en))
    }

    @Test func degradedIsReflected() async throws {
        let f = Self.fixture(); defer { f.cleanup() }
        // A store path that is a plain file inside a "directory" makes appends fail, but reading must not throw.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("blocker-\(UUID().uuidString)")
        try Data().write(to: blocker); defer { try? FileManager.default.removeItem(at: blocker) }
        let bad = InsightsStore(url: blocker.appendingPathComponent("x/insights.sqlite"))
        let defaults = UserDefaults(suiteName: "vs-deg-\(UUID().uuidString)")!
        let tick = Date(timeIntervalSince1970: 1_800_000_000)
        let service = InsightsService(
            store: bad, source: IdleSource(),
            headset: { HeadsetInsightsSnapshot(connected: true, noiseMode: .anc, battery: 50, charging: false) },
            settings: defaults, tick: .milliseconds(1), now: { tick })
        await service.tick(); await service.tick()   // second tick closes nothing, flush forces a write attempt
        await service.stop()
        let s = await InsightsViewState.make(range: .today, store: bad, service: service, now: Self.now, calendar: Self.calendar, locale: Self.en)
        #expect(service.degraded && s.degraded)
        #expect(s.note == Strings.text("insights.degraded", locale: Self.en))
    }

    @Test func appsSortedDescendingWithTopEightAndOther() async throws {
        let f = Self.fixture(); defer { f.cleanup() }
        var items: [ActivityInterval] = []
        for i in 1...10 { items.append(Self.act("app\(i)", hoursAgo: 11, seconds: Double(i) * 100)) }
        try await f.store.append(RecorderOutput(activity: items))
        let s = await Self.make(.today, f)
        #expect(s.apps.count == 9)
        #expect(s.apps.prefix(8).map(\.id) == (3...10).reversed().map { "app\($0)" })
        let other = try #require(s.apps.last)
        #expect(other.isOther && other.name == Strings.text("insights.other", locale: Self.en))
        #expect(other.listening == 300 && other.call == 0)
    }

    @Test func exactlyEightAppsHaveNoOtherRow() async throws {
        let f = Self.fixture(); defer { f.cleanup() }
        try await f.store.append(RecorderOutput(activity: (1...8).map { Self.act("a\($0)", hoursAgo: 11, seconds: Double($0) * 60) }))
        let s = await Self.make(.today, f)
        #expect(s.apps.count == 8 && !s.apps.contains { $0.isOther })
    }

    @Test func listeningAndCallAreNeverCombined() async throws {
        let f = Self.fixture(); defer { f.cleanup() }
        try await f.store.append(RecorderOutput(activity: [
            Self.act("zoom", .listening, hoursAgo: 10, seconds: 600),
            Self.act("zoom", .call, hoursAgo: 10, seconds: 600),
        ]))
        let s = await Self.make(.today, f)
        #expect(s.totals == InsightsTotals(listening: 600, call: 600))
        #expect(s.apps.count == 1 && s.apps[0].listening == 600 && s.apps[0].call == 600)
    }

    @Test func noisePercentagesSumToOneHundredAndAreEmptyForZero() async throws {
        let f = Self.fixture(); defer { f.cleanup() }
        #expect(await Self.make(.today, f).noise.isEmpty)
        let start = Self.now.addingTimeInterval(-6 * 3600)
        try await f.store.append(RecorderOutput(noise: [
            NoiseInterval(mode: .anc, start: start, end: start.addingTimeInterval(100)),
            NoiseInterval(mode: .transparency, start: start.addingTimeInterval(100), end: start.addingTimeInterval(200)),
            NoiseInterval(mode: .off, start: start.addingTimeInterval(200), end: start.addingTimeInterval(300)),
        ]))
        let s = await Self.make(.today, f)
        #expect(s.noise.map(\.percent).reduce(0, +) == 100)
        #expect(s.noise.map(\.percent).sorted() == [33, 33, 34])
    }

    @Test func largestRemainderIsDeterministic() {
        let shares = [NoiseShare(mode: .anc, seconds: 1), NoiseShare(mode: .transparency, seconds: 1), NoiseShare(mode: .off, seconds: 1)]
        let rows = InsightsViewState.noiseRows(shares)
        #expect(rows.map(\.percent) == [34, 33, 33])
        #expect(InsightsViewState.noiseRows([]).isEmpty)
        #expect(InsightsViewState.noiseRows([NoiseShare(mode: .anc, seconds: 0)]).isEmpty)
        #expect(InsightsViewState.noiseRows([NoiseShare(mode: .anc, seconds: 5)]).map(\.percent) == [100])
    }

    @Test func daysCoverEveryDayInTheRangeIncludingZeroDays() async throws {
        let f = Self.fixture(); defer { f.cleanup() }
        try await f.store.append(RecorderOutput(activity: [Self.act("a", hoursAgo: 12 + 24 * 3, seconds: 3600)]))
        let week = await Self.make(.week, f)
        #expect(week.days.count == 7)
        #expect(week.days.last?.day == Self.calendar.startOfDay(for: Self.now))
        #expect(week.days.filter { $0.listening > 0 }.count == 1)
        #expect(await Self.make(.today, f).days.count == 1)
        #expect(await Self.make(.month, f).days.count == 30)
        let ordered = week.days.map(\.day)
        #expect(ordered == ordered.sorted())
    }

    @Test func rangeIsAppliedToAppTotals() async throws {
        let f = Self.fixture(); defer { f.cleanup() }
        try await f.store.append(RecorderOutput(activity: [
            Self.act("old", hoursAgo: 24 * 10, seconds: 600),
            Self.act("new", hoursAgo: 2, seconds: 600),
        ]))
        #expect(await Self.make(.today, f).apps.map(\.id) == ["new"])
        #expect(await Self.make(.week, f).apps.map(\.id) == ["new"])
        #expect(Set(await Self.make(.month, f).apps.map(\.id)) == ["new", "old"])
    }

    @Test func batteryPointsAreMapped() async throws {
        let f = Self.fixture(); defer { f.cleanup() }
        try await f.store.append(RecorderOutput(battery: [BatteryReading(time: Self.now.addingTimeInterval(-3600), percent: 80, charging: false)]))
        let s = await Self.make(.today, f)
        #expect(s.battery.map(\.percent) == [80])
        #expect(!s.isEmpty)
    }

    @Test func formatDurationEnglishAndTurkish() {
        let en = Self.en, tr = Self.tr
        #expect(InsightsViewState.formatDuration(0, locale: en) == "0 min")
        #expect(InsightsViewState.formatDuration(0, locale: tr) == "0 dk")
        #expect(InsightsViewState.formatDuration(.nan, locale: en) == "0 min")
        #expect(InsightsViewState.formatDuration(.infinity, locale: en) == "0 min")
        #expect(InsightsViewState.formatDuration(1, locale: en) == "< 1 min")
        #expect(InsightsViewState.formatDuration(59, locale: en) == "< 1 min")
        #expect(InsightsViewState.formatDuration(60, locale: en) == "1 min")
        #expect(InsightsViewState.formatDuration(3599, locale: en) == "59 min")
        #expect(InsightsViewState.formatDuration(3600, locale: en) == "1 h 00 min")
        #expect(InsightsViewState.formatDuration(7500, locale: en) == "2 h 05 min")
        #expect(InsightsViewState.formatDuration(59, locale: tr) == "< 1 dk")
        #expect(InsightsViewState.formatDuration(60, locale: tr) == "1 dk")
        #expect(InsightsViewState.formatDuration(3599, locale: tr) == "59 dk")
        #expect(InsightsViewState.formatDuration(7500, locale: tr) == "2 sa 05 dk")
        #expect(InsightsViewState.formatDuration(7500, locale: Locale(identifier: "de")) == "2 h 05 min")
    }

    @Test func insightsKeysExistInBothLanguages() {
        let keys = ["insights.title", "insights.range.today", "insights.range.week", "insights.range.month", "insights.listening",
                    "insights.calls", "insights.perApp", "insights.other", "insights.noiseShare", "insights.dailyHours",
                    "insights.battery", "insights.recording", "insights.recording.hint", "insights.exclude", "insights.deleteHistory",
                    "insights.deleteConfirm", "insights.export", "insights.empty", "insights.unsupported", "insights.degraded", "panel.insights",
                    "insights.excluded", "insights.remove", "insights.deleteFailed", "insights.cancel", "insights.exportFailed",
                    "insights.unit.minute", "insights.unit.hour", "insights.day", "insights.time", "insights.recording.toggle",
                    "insights.a11y.daily", "insights.a11y.battery", "insights.app.webkit", "insights.app.systemSounds"]
        for key in keys {
            #expect(Strings.allKeys.contains(key), "\(key)")
            #expect(Strings.text(key, locale: Self.en) != Strings.text(key, locale: Self.tr), "\(key)")
        }
        #expect(Strings.text("insights.recording.hint", locale: Self.en) == "Only app names and times are saved, on this Mac. Nothing leaves it.")
        #expect(Strings.text("insights.unsupported", locale: Self.en) == "Needs macOS 14.2 or later")
    }

    @Test func unsupportedAndDegradedShowBothNotes() async throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("blocker-\(UUID().uuidString)")
        try Data().write(to: blocker); defer { try? FileManager.default.removeItem(at: blocker) }
        let bad = InsightsStore(url: blocker.appendingPathComponent("x/insights.sqlite"))
        let service = InsightsService(
            store: bad, source: IdleSource(),
            headset: { HeadsetInsightsSnapshot(connected: true, noiseMode: .anc, battery: 50, charging: false) },
            settings: UserDefaults(suiteName: "vs-both-\(UUID().uuidString)")!, tick: .milliseconds(1), now: { Date(timeIntervalSince1970: 1_800_000_000) })
        await service.tick(); await service.stop()
        let s = await InsightsViewState.make(range: .today, store: bad, service: service, now: Self.now, calendar: Self.calendar, locale: Self.en, unsupported: true)
        #expect(s.notes.map(\.isWarning) == [false, true])
        #expect(s.notes.map(\.text) == [Strings.text("insights.unsupported", locale: Self.en), Strings.text("insights.degraded", locale: Self.en)])
    }

    @Test func demoStateIsEmptyNotRecordingAndNeverTouchesAStore() {
        let s = InsightsViewState.demo(range: .week, now: Self.now, calendar: Self.calendar, locale: Self.en)
        #expect(s.isEmpty && !s.recording && !s.degraded && !s.unsupported && s.days.count == 7)
        #expect(s.note == Strings.text("insights.empty", locale: Self.en))
    }

    // MARK: DST (America/New_York, spring forward 2026-03-08 at 02:00 local)

    static var ny: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    static func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    static func makeNY(_ range: InsightsRange, now: Date, _ f: (store: InsightsStore, service: InsightsService, cleanup: () -> Void)) async -> InsightsViewState {
        await InsightsViewState.make(range: range, store: f.store, service: f.service, now: now, calendar: ny, locale: en)
    }

    @Test func dayCountsAndFirstDayOnTheSpringForwardDay() async {
        let f = Self.fixture(); defer { f.cleanup() }
        let now = Self.utc(2026, 3, 8, 15)   // 11:00 EDT, after the jump
        let today = await Self.makeNY(.today, now: now, f)
        #expect(today.days.count == 1 && today.days.first?.day == Self.utc(2026, 3, 8, 5))   // 00:00 EST
        let week = await Self.makeNY(.week, now: now, f)
        #expect(week.days.count == 7 && week.days.first?.day == Self.utc(2026, 3, 2, 5) && week.days.last?.day == Self.utc(2026, 3, 8, 5))
        let month = await Self.makeNY(.month, now: now, f)
        #expect(month.days.count == 30 && month.days.first?.day == Self.utc(2026, 2, 7, 5))
        #expect(Set(week.days.map(\.day)).count == 7)
    }

    @Test func dayRowsMatchTheStoreKeysAcrossTheDSTJump() async throws {
        let f = Self.fixture(); defer { f.cleanup() }
        func iv(_ a: Date, _ b: Date) -> ActivityInterval {
            ActivityInterval(app: "x", appName: nil, kind: .listening, route: .bluetooth, noiseMode: nil, start: a, end: b)
        }
        try await f.store.append(RecorderOutput(activity: [
            iv(Self.utc(2026, 3, 8, 4), Self.utc(2026, 3, 8, 5, 30)),    // 23:00 EST Mar 7 .. 00:30 EST Mar 8
            iv(Self.utc(2026, 3, 8, 5, 30), Self.utc(2026, 3, 8, 7, 30)), // 00:30 EST .. 03:30 EDT (2 real hours)
            iv(Self.utc(2026, 3, 9, 8), Self.utc(2026, 3, 9, 9)),         // 04:00-05:00 EDT Mar 9
        ]))
        let s = await Self.makeNY(.week, now: Self.utc(2026, 3, 9, 15), f)
        let byDay = Dictionary(uniqueKeysWithValues: s.days.map { ($0.day, $0.listening) })
        #expect(s.days.count == 7 && s.days.last?.day == Self.utc(2026, 3, 9, 4))   // 00:00 EDT
        #expect(byDay[Self.utc(2026, 3, 7, 5)] == 3600)
        #expect(byDay[Self.utc(2026, 3, 8, 5)] == 9000)
        #expect(byDay[Self.utc(2026, 3, 9, 4)] == 3600)
        #expect(s.totals.listening == 3600 + 9000 + 3600)
    }

    @Test func nothingAfterNowIsCountedAndEndOfTodayIsExclusive() async throws {
        let f = Self.fixture(); defer { f.cleanup() }
        let now = Self.utc(2026, 3, 8, 15)
        func iv(_ a: Date, _ b: Date) -> ActivityInterval {
            ActivityInterval(app: "x", appName: nil, kind: .listening, route: .bluetooth, noiseMode: nil, start: a, end: b)
        }
        try await f.store.append(RecorderOutput(activity: [
            iv(now.addingTimeInterval(-600), now.addingTimeInterval(600)),   // straddles now: only 600 s count
            iv(now.addingTimeInterval(3600), now.addingTimeInterval(7200)),  // later today: not counted
        ]))
        let s = await Self.makeNY(.today, now: now, f)
        #expect(s.totals.listening == 600 && s.days.first?.listening == 600)
    }

    // MARK: LatestLoader

    @Test func aSlowOlderLoadNeverOverwritesANewerOne() async {
        let loader = LatestLoader<String>()
        final class Gate { var continuation: CheckedContinuation<Void, Never>?; var waiting = false }
        let slow = Gate()
        var applied: [String] = []
        loader.load(produce: {
            await withCheckedContinuation { c in slow.continuation = c; slow.waiting = true }
            return "old"
        }, apply: { applied.append($0) })
        while !slow.waiting { await Task.yield() }
        loader.load(produce: { "new" }, apply: { applied.append($0) })
        await loader.isIdleForTests?.value
        slow.continuation?.resume()
        for _ in 0..<50 { await Task.yield() }
        #expect(applied == ["new"])
    }

    @Test func cancelDropsThePendingResult() async {
        let loader = LatestLoader<Int>()
        var applied: [Int] = []
        loader.load(produce: { await Task.yield(); return 1 }, apply: { applied.append($0) })
        loader.cancel()
        for _ in 0..<50 { await Task.yield() }
        #expect(applied.isEmpty)
        loader.load(produce: { 2 }, apply: { applied.append($0) })
        await loader.isIdleForTests?.value
        #expect(applied == [2])
    }

    @Test func friendlyNamesForSystemProcessesOnlyWhenNoAppName() async throws {
        let f = Self.fixture(); defer { f.cleanup() }
        func iv(_ app: String, name: String?, hours: Double) -> ActivityInterval {
            let start = Self.now.addingTimeInterval(-hours * 3600)
            return ActivityInterval(app: app, appName: name, kind: .listening, route: .bluetooth, noiseMode: nil, start: start, end: start.addingTimeInterval(600))
        }
        try await f.store.append(RecorderOutput(activity: [
            iv("com.apple.WebKit.GPU", name: nil, hours: 5),
            iv("systemsoundserverd", name: nil, hours: 6),
            iv("com.apple.WebKit.Networking", name: "Custom", hours: 7),
            iv("com.example.unknown", name: nil, hours: 8),
        ]))
        for (locale, web, sounds) in [(Self.en, "Safari & WebKit apps", "System sounds"), (Self.tr, "Safari ve WebKit uygulamaları", "Sistem sesleri")] {
            let s = await Self.make(.today, f, locale: locale)
            let names = Dictionary(uniqueKeysWithValues: s.apps.map { ($0.id, $0.name) })
            #expect(names["com.apple.WebKit.GPU"] == web)
            #expect(names["systemsoundserverd"] == sounds)
            #expect(names["com.apple.WebKit.Networking"] == "Custom")
            #expect(names["com.example.unknown"] == "com.example.unknown")
        }
        let csv = try await f.store.exportCSV()
        #expect(csv.contains("com.apple.WebKit.GPU") && csv.contains("systemsoundserverd"))
        #expect(!csv.contains("Safari & WebKit") && !csv.contains("System sounds"))
    }
}
