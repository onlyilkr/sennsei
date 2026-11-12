import Foundation
import Testing
import HeadsetCore
@testable import SennseiCore

@Suite struct InsightsStoreTests {
    static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("insights-\(UUID().uuidString)", isDirectory: true)
    }
    static func storeURL(_ dir: URL) -> URL { dir.appendingPathComponent("db/insights.sqlite") }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func ago(days: Double, plus s: TimeInterval = 0) -> Date { now.addingTimeInterval(-days * 86_400 + s) }
    static func act(_ app: String, _ kind: ActivityKind = .listening, name: String? = nil, from: Date, seconds: TimeInterval) -> ActivityInterval {
        ActivityInterval(app: app, appName: name, kind: kind, route: .bluetooth, noiseMode: .anc, start: from, end: from.addingTimeInterval(seconds))
    }
    static func everything() -> DateInterval { DateInterval(start: now.addingTimeInterval(-800 * 86_400), end: now.addingTimeInterval(86_400)) }

    @Test func noFileIsCreatedUntilTheFirstAppend() async throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = Self.storeURL(dir)
        let store = InsightsStore(url: url)
        let range = Self.everything()
        #expect(try await store.perApp(range).isEmpty)
        #expect(try await store.totals(range) == InsightsTotals(listening: 0, call: 0))
        #expect(try await store.noiseShares(range).isEmpty)
        #expect(try await store.dailySeconds(range, calendar: .current).isEmpty)
        #expect(try await store.batteryReadings(range).isEmpty)
        try await store.prune(now: Self.now)
        try await store.deleteAll()
        try await store.delete(app: "x")
        _ = try await store.exportCSV()
        #expect(!FileManager.default.fileExists(atPath: dir.path))

        try await store.append(RecorderOutput(activity: [Self.act("a", from: Self.now, seconds: 10)]))
        let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        #expect(dirMode == 0o700)
    }

    @Test func appendAndAggregatePerAppTotalsAndDailySeconds() async throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = InsightsStore(url: Self.storeURL(dir))
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let day0 = cal.startOfDay(for: Self.ago(days: 3))
        try await store.append(RecorderOutput(activity: [
            Self.act("chrome", name: "Chrome", from: day0.addingTimeInterval(3600), seconds: 600),
            Self.act("chrome", .call, name: "Chrome", from: day0.addingTimeInterval(3600), seconds: 300),
            Self.act("music", name: "Music", from: day0.addingTimeInterval(7200), seconds: 100),
            Self.act("music", name: "Music", from: day0.addingTimeInterval(86_400 + 60), seconds: 50),
        ]))
        let range = DateInterval(start: day0, end: day0.addingTimeInterval(3 * 86_400))
        let apps = try await store.perApp(range)
        #expect(apps == [
            AppTotal(app: "chrome", appName: "Chrome", listening: 600, call: 300),
            AppTotal(app: "music", appName: "Music", listening: 150, call: 0),
        ])
        #expect(try await store.totals(range) == InsightsTotals(listening: 750, call: 300))
        let days = try await store.dailySeconds(range, calendar: cal)
        #expect(days == [
            DaySeconds(day: day0, listening: 700, call: 300),
            DaySeconds(day: day0.addingTimeInterval(86_400), listening: 50, call: 0),
        ])
        // A range that cuts an interval in half only counts the overlap.
        let half = DateInterval(start: day0.addingTimeInterval(3600 + 300), end: day0.addingTimeInterval(7200 - 1))
        #expect(try await store.totals(half) == InsightsTotals(listening: 300, call: 0))
    }

    @Test func noiseSharesAndBatteryReadingsRoundTrip() async throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = InsightsStore(url: Self.storeURL(dir))
        let t0 = Self.ago(days: 1)
        try await store.append(RecorderOutput(
            noise: [
                NoiseInterval(mode: .anc, start: t0, end: t0.addingTimeInterval(100)),
                NoiseInterval(mode: .off, start: t0.addingTimeInterval(100), end: t0.addingTimeInterval(130)),
                NoiseInterval(mode: .anc, start: t0.addingTimeInterval(130), end: t0.addingTimeInterval(160)),
            ],
            battery: [
                BatteryReading(time: t0, percent: 80, charging: nil),
                BatteryReading(time: t0.addingTimeInterval(60), percent: 79, charging: false),
                BatteryReading(time: t0.addingTimeInterval(120), percent: 85, charging: true),
            ]))
        let range = DateInterval(start: t0, end: t0.addingTimeInterval(3600))
        #expect(try await store.noiseShares(range) == [NoiseShare(mode: .anc, seconds: 130), NoiseShare(mode: .off, seconds: 30)])
        let readings = try await store.batteryReadings(range)
        #expect(readings.map(\.percent) == [80, 79, 85])
        #expect(readings.map(\.charging) == [nil, false, true])
        #expect(readings.first?.time == t0)
    }

    @Test func pruneRollsOldRawIntervalsIntoDailySummariesWithoutDoubleCounting() async throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = Self.storeURL(dir)
        let store = InsightsStore(url: url)
        let old = Calendar.current.startOfDay(for: Self.ago(days: 100)).addingTimeInterval(3600)
        let recent = Self.ago(days: 5)
        try await store.append(RecorderOutput(
            activity: [
                Self.act("a", name: "A", from: old, seconds: 600),
                Self.act("a", .call, name: "A", from: old.addingTimeInterval(1000), seconds: 60),
                Self.act("a", name: "A", from: recent, seconds: 120),
            ],
            noise: [NoiseInterval(mode: .anc, start: old, end: old.addingTimeInterval(60))],
            battery: [BatteryReading(time: old, percent: 50, charging: nil)]))
        let range = Self.everything()
        let before = try await store.perApp(range)
        #expect(before == [AppTotal(app: "a", appName: "A", listening: 720, call: 60)])

        try await store.prune(now: Self.now)
        try await store.prune(now: Self.now) // idempotent
        #expect(try await store.perApp(range) == before)
        #expect(try await store.noiseShares(range).isEmpty)
        #expect(try await store.batteryReadings(range).isEmpty)

        let csv = try await store.exportCSV()
        #expect(csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }.count == 2) // header + the recent interval

        // Days from the summary table appear in the daily series.
        let days = try await store.dailySeconds(range, calendar: .current)
        #expect(days.count == 2)
        #expect(days.first?.listening == 600)
        #expect(days.first?.call == 60)

        // A range that only covers the old day still sees the summary.
        let oldOnly = DateInterval(start: Calendar.current.startOfDay(for: old), end: Calendar.current.startOfDay(for: old).addingTimeInterval(86_400))
        #expect(try await store.totals(oldOnly) == InsightsTotals(listening: 600, call: 60))
    }

    @Test func summariesOlderThanTwelveMonthsAreDeleted() async throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = InsightsStore(url: Self.storeURL(dir))
        let ancient = Self.ago(days: 400)
        let mid = Self.ago(days: 200)
        try await store.append(RecorderOutput(activity: [
            Self.act("a", from: ancient, seconds: 100),
            Self.act("a", from: mid, seconds: 40),
        ]))
        try await store.prune(now: Self.now)
        #expect(try await store.totals(Self.everything()) == InsightsTotals(listening: 40, call: 0))
    }

    @Test func deleteAllEmptiesEverythingAndDeleteAppIsScoped() async throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = Self.storeURL(dir)
        let store = InsightsStore(url: url)
        let t = Self.ago(days: 1)
        try await store.append(RecorderOutput(
            activity: [Self.act("a", from: t, seconds: 60), Self.act("b", from: t, seconds: 30),
                       Self.act("a", from: Self.ago(days: 120), seconds: 10)],
            noise: [NoiseInterval(mode: .anc, start: t, end: t.addingTimeInterval(10))],
            battery: [BatteryReading(time: t, percent: 10, charging: nil)]))
        try await store.prune(now: Self.now)
        try await store.delete(app: "a")
        let range = Self.everything()
        #expect(try await store.perApp(range).map(\.app) == ["b"])
        try await store.deleteAll()
        #expect(try await store.perApp(range).isEmpty)
        #expect(try await store.noiseShares(range).isEmpty)
        #expect(try await store.batteryReadings(range).isEmpty)
        // The file stays usable afterwards.
        try await store.append(RecorderOutput(activity: [Self.act("c", from: t, seconds: 5)]))
        #expect(try await store.perApp(range).map(\.app) == ["c"])
    }

    @Test func aCorruptFileThrowsAndIsLeftUntouched() async throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("insights.sqlite")
        let bytes = Data("not a database, definitely not a database at all, padding padding padding padding".utf8)
        try bytes.write(to: url)
        let store = InsightsStore(url: url)
        let output = RecorderOutput(activity: [Self.act("a", from: Self.now, seconds: 1)])
        await #expect(throws: InsightsStoreError.self) { try await store.append(output) }
        await #expect(throws: InsightsStoreError.self) { _ = try await store.perApp(Self.everything()) }
        await #expect(throws: InsightsStoreError.self) { try await store.prune(now: Self.now) }
        await #expect(throws: InsightsStoreError.self) { try await store.deleteAll() }
        await #expect(throws: InsightsStoreError.self) { try await store.delete(app: "a") }
        await #expect(throws: InsightsStoreError.self) { _ = try await store.exportCSV() }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func sqlSpecialCharactersInAppNamesAreStoredLiterally() async throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = InsightsStore(url: Self.storeURL(dir))
        let nasty = "x'); DROP TABLE activity;--"
        let t = Self.ago(days: 1)
        try await store.append(RecorderOutput(activity: [Self.act(nasty, name: nasty, from: t, seconds: 20)]))
        try await store.append(RecorderOutput(activity: [Self.act("other", from: t, seconds: 5)]))
        let apps = try await store.perApp(Self.everything())
        #expect(apps.first == AppTotal(app: nasty, appName: nasty, listening: 20, call: 0))
        #expect(apps.count == 2)
        try await store.delete(app: nasty)
        #expect(try await store.perApp(Self.everything()).map(\.app) == ["other"])
    }

    @Test func queriesNeverBlockTheCallerBeyondTheActor() async throws {
        // Compile-time contract: every API is actor-isolated and async, so callers must await.
        let store = InsightsStore(url: Self.storeURL(Self.tempDir()))
        let totals: InsightsTotals = try await store.totals(Self.everything())
        #expect(totals == InsightsTotals(listening: 0, call: 0))
    }

    // MARK: - Fix round 1

    static var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    /// Minimal RFC 4180 reader: records split on CRLF outside quotes.
    static func records(_ csv: String) -> [String] {
        var out: [String] = [], current = String.UnicodeScalarView(), quoted = false
        let scalars = Array(csv.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "\"" { quoted.toggle(); current.append(c) }
            else if !quoted, c == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" {
                out.append(String(current)); current = .init(); i += 1
            } else { current.append(c) }
            i += 1
        }
        if !current.isEmpty { out.append(String(current)) }
        return out
    }

    @Test func emptyAppendCreatesNothing() async throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = InsightsStore(url: Self.storeURL(dir))
        try await store.append(RecorderOutput())
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func hostileNamesSurviveExportWithoutInjectingRecords() async throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = InsightsStore(url: Self.storeURL(dir))
        let t = Self.ago(days: 1)
        try await store.append(RecorderOutput(activity: [
            ActivityInterval(app: "=evil\r=1", appName: "a\r\n=cmd", kind: .listening, route: .usb, noiseMode: nil, start: t, end: t.addingTimeInterval(5)),
            ActivityInterval(app: "+x\n@y", appName: "a\n=cmd", kind: .call, route: .usb, noiseMode: nil, start: t.addingTimeInterval(10), end: t.addingTimeInterval(15)),
            ActivityInterval(app: "b", appName: "a\r=cmd", kind: .call, route: .usb, noiseMode: nil, start: t.addingTimeInterval(20), end: t.addingTimeInterval(25)),
        ]))
        let csv = try await store.exportCSV()
        let records = Self.records(csv)
        #expect(records.count == 4)
        for record in records.dropFirst() {
            #expect(record.unicodeScalars.first.map { !"=+-@\t\r".unicodeScalars.contains($0) } == true)
        }
        #expect(InsightsCSV.field("a\r\n=cmd") == "\"a\r\n=cmd\"")
        #expect(InsightsCSV.field("a\n=cmd") == "\"a\n=cmd\"")
        #expect(InsightsCSV.field("a\r=cmd") == "\"a\r=cmd\"")
        #expect(records[1].contains("\"'=evil\r=1\""))
        #expect(records[1].contains("\"a\r\n=cmd\""))
    }

    @Test func displayNameSurvivesRollUpAndIsRemovedWithTheApp() async throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = InsightsStore(url: Self.storeURL(dir))
        let cal = Self.utc
        try await store.append(RecorderOutput(activity: [
            Self.act("gone", name: "Old Name", from: Self.ago(days: 130), seconds: 30),
            Self.act("gone", name: "Gone", from: Self.ago(days: 120), seconds: 60),
            Self.act("gone", name: nil, from: Self.ago(days: 119), seconds: 10),
        ]))
        try await store.prune(now: Self.now, calendar: cal)
        #expect(try await store.perApp(Self.everything(), calendar: cal)
            == [AppTotal(app: "gone", appName: "Gone", listening: 100, call: 0)])
        try await store.delete(app: "gone")
        #expect(try await store.perApp(Self.everything(), calendar: cal).isEmpty)
        try await store.append(RecorderOutput(activity: [Self.act("gone", from: Self.ago(days: 1), seconds: 7)]))
        #expect(try await store.perApp(Self.everything(), calendar: cal)
            == [AppTotal(app: "gone", appName: nil, listening: 7, call: 0)])
    }

    @Test func rangeStartingMidRolledDayCountsTheWholeSummaryDay() async throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = InsightsStore(url: Self.storeURL(dir))
        let cal = Self.utc
        let day = cal.startOfDay(for: Self.ago(days: 100))
        try await store.append(RecorderOutput(activity: [
            Self.act("a", from: day.addingTimeInterval(3600), seconds: 600),
            Self.act("a", from: day.addingTimeInterval(50_000), seconds: 400),
            Self.act("a", from: Self.ago(days: 5), seconds: 120),
        ]))
        try await store.prune(now: Self.now, calendar: cal)
        // Starts at noon of the rolled day: only the 400 s interval is after it, but the summary is whole.
        let range = DateInterval(start: day.addingTimeInterval(43_200), end: Self.now.addingTimeInterval(86_400))
        #expect(try await store.totals(range, calendar: cal) == InsightsTotals(listening: 1120, call: 0))
        // Starting on the next day excludes the summary.
        let after = DateInterval(start: day.addingTimeInterval(86_400), end: Self.now.addingTimeInterval(86_400))
        #expect(try await store.totals(after, calendar: cal) == InsightsTotals(listening: 120, call: 0))
    }

    @Test func aNewerSchemaVersionIsRefusedAndLeftUntouched() async throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = Self.storeURL(dir)
        let store = InsightsStore(url: url)
        try await store.append(RecorderOutput(activity: [Self.act("a", from: Self.ago(days: 1), seconds: 5)]))
        do {
            let db = try SQLiteConnection(path: url.path, readOnly: false)
            try db.exec("UPDATE meta SET value = '2' WHERE key = 'schema_version'")
        }
        let bytes = try Data(contentsOf: url)
        let output = RecorderOutput(activity: [Self.act("b", from: Self.now, seconds: 1)])
        await #expect(throws: InsightsStoreError.self) { try await store.append(output) }
        await #expect(throws: InsightsStoreError.self) { _ = try await store.perApp(Self.everything()) }
        await #expect(throws: InsightsStoreError.self) { try await store.prune(now: Self.now) }
        await #expect(throws: InsightsStoreError.self) { try await store.deleteAll() }
        #expect(try Data(contentsOf: url) == bytes)
    }

    // MARK: - Fix round 2

    /// Splits one record into unquoted fields (scalar-based, RFC 4180).
    static func fields(_ record: String) -> [String] {
        var out: [String] = [], cur = String.UnicodeScalarView(), quoted = false
        let sc = Array(record.unicodeScalars)
        var i = 0
        while i < sc.count {
            let c = sc[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < sc.count, sc[i + 1] == "\"" { cur.append(c); i += 1 } else { quoted = false }
                } else { cur.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { out.append(String(cur)); cur = .init() }
            else { cur.append(c) }
            i += 1
        }
        out.append(String(cur))
        return out
    }

    @Test func combiningMarksCannotBreakQuotingOrTheFormulaGuard() async throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = InsightsStore(url: Self.storeURL(dir))
        let t = Self.ago(days: 1)
        let quoteName = "a\"\u{301}b,c"
        let names = [quoteName, "=\u{301}cmd", "+\u{301}x", "@\u{301}y"]
        try await store.append(RecorderOutput(activity: names.enumerated().map { i, n in
            ActivityInterval(app: "app\(i)", appName: n, kind: .listening, route: .usb, noiseMode: nil,
                             start: t.addingTimeInterval(Double(i) * 10), end: t.addingTimeInterval(Double(i) * 10 + 5))
        }))
        let records = Self.records(try await store.exportCSV())
        #expect(records.count == 5)
        for record in records.dropFirst() {
            #expect(record.unicodeScalars.first.map { !"=+-@\t\r".unicodeScalars.contains($0) } == true)
        }
        #expect(InsightsCSV.field(quoteName).unicodeScalars.filter { $0 == "\"" }.count == 4)
        let parsed = records.dropFirst().map { Self.fields($0) }
        #expect(parsed.allSatisfy { $0.count == 7 })
        #expect(parsed[0][3].unicodeScalars.elementsEqual(quoteName.unicodeScalars))
        #expect(parsed[1][3].unicodeScalars.elementsEqual("'=\u{301}cmd".unicodeScalars))
        #expect(parsed[2][3].unicodeScalars.elementsEqual("'+\u{301}x".unicodeScalars))
        #expect(parsed[3][3].unicodeScalars.elementsEqual("'@\u{301}y".unicodeScalars))
    }
}
