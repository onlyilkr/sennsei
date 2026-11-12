import Foundation
import Testing
import HeadsetCore
@testable import SennseiCore

@Suite struct InsightsRecorderTests {
    static func calendar(_ id: String = "UTC") -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: id)!
        return c
    }

    /// 2026-06-01 12:00:00 UTC
    static let base = Date(timeIntervalSince1970: 1_780_315_200)
    static func t(_ s: TimeInterval) -> Date { base.addingTimeInterval(s) }

    static func chrome(output: Bool = true, input: Bool = false) -> ProcessActivity {
        ProcessActivity(bundleID: "com.google.Chrome", appName: "Chrome", outputRunning: output, inputRunning: input, route: .bluetooth)
    }
    static func sample(_ s: TimeInterval, _ procs: [ProcessActivity] = [], connected: Bool = true,
                       mode: NoiseMode? = nil, battery: Int? = nil) -> InsightsSample {
        InsightsSample(time: t(s), processes: procs, connected: connected, noiseMode: mode, battery: battery, charging: nil)
    }
    static func recorder(excluded: Set<String> = []) -> InsightsRecorder {
        InsightsRecorder(calendar: calendar(), excluded: excluded)
    }
    static func merge(_ outs: [RecorderOutput]) -> RecorderOutput {
        var r = RecorderOutput()
        for o in outs { r.activity += o.activity; r.noise += o.noise; r.battery += o.battery }
        return r
    }
    static func run(_ rec: inout InsightsRecorder, _ samples: [InsightsSample]) -> RecorderOutput {
        var outs = samples.map { rec.ingest($0) }
        outs.append(rec.flush())
        return merge(outs)
    }

    @Test func listeningBecomesOneIntervalAndMergesShortGaps() {
        var rec = Self.recorder()
        let out = Self.run(&rec, [0, 5, 10, 15, 20].map { Self.sample($0, [Self.chrome()]) }
                           + [Self.sample(25), Self.sample(30, [Self.chrome()])])
        #expect(out.activity.count == 1)
        #expect(out.activity[0].start == Self.t(0)); #expect(out.activity[0].end == Self.t(35))
        #expect(out.activity[0].kind == .listening)
        #expect(out.activity[0].app == "com.google.Chrome"); #expect(out.activity[0].appName == "Chrome")
    }

    @Test func aGapOverTenSecondsSplitsTheInterval() {
        var rec = Self.recorder()
        let out = Self.run(&rec, [Self.sample(0, [Self.chrome()]), Self.sample(5, [Self.chrome()]),
                                  Self.sample(10), Self.sample(15), Self.sample(20), Self.sample(25, [Self.chrome()])])
        #expect(out.activity.map(\.start) == [Self.t(0), Self.t(25)])
        #expect(out.activity.map(\.end) == [Self.t(10), Self.t(30)])
    }

    @Test func outputPlusInputIsACallAndInputAloneIsIgnored() {
        var rec = Self.recorder()
        let mic = ProcessActivity(bundleID: "com.mic", appName: nil, outputRunning: false, inputRunning: true, route: .usb)
        let out = Self.run(&rec, [Self.sample(0, [Self.chrome(input: true), mic]), Self.sample(5, [Self.chrome(input: true), mic])])
        #expect(out.activity.count == 1)
        #expect(out.activity[0].kind == .call)
        #expect(out.activity[0].end == Self.t(10))
    }

    @Test func disconnectClosesEverythingAtOnce() {
        var rec = Self.recorder()
        var outs = [rec.ingest(Self.sample(0, [Self.chrome()], mode: .anc)), rec.ingest(Self.sample(5, [Self.chrome()], mode: .anc))]
        let closing = rec.ingest(Self.sample(7, connected: false))
        outs.append(closing)
        #expect(closing.activity.map(\.end) == [Self.t(10)])
        #expect(closing.noise.map(\.end) == [Self.t(10)])
        outs.append(rec.flush())
        #expect(Self.merge(outs).activity.count == 1)
    }

    @Test func aSleepGapIsNotCountedAsListening() {
        var rec = Self.recorder()
        let out = Self.run(&rec, [Self.sample(0, [Self.chrome()]), Self.sample(5, [Self.chrome()]), Self.sample(3600, [Self.chrome()])])
        #expect(out.activity.map(\.start) == [Self.t(0), Self.t(3600)])
        #expect(out.activity.map(\.end) == [Self.t(10), Self.t(3605)])
    }

    @Test func aClockGoingBackwardsNeverProducesNegativeOrOverlappingIntervals() {
        var rec = Self.recorder()
        let out = Self.run(&rec, [Self.sample(100, [Self.chrome()], mode: .anc), Self.sample(105, [Self.chrome()], mode: .anc),
                                  Self.sample(50, [Self.chrome()], mode: .anc), Self.sample(55, [Self.chrome()], mode: .anc)])
        // The pre-jump interval closes at 110; the post-jump samples (50, 55) lie before that watermark, so they are lost.
        #expect(out.activity.map(\.start) == [Self.t(100)]); #expect(out.activity.map(\.end) == [Self.t(110)])
        #expect(out.noise.map(\.start) == [Self.t(100)]); #expect(out.noise.map(\.end) == [Self.t(110)])
    }

    @Test func listeningIsLostUntilTheNewClockPassesTheWatermark() {
        var rec = Self.recorder()
        var samples = [Self.sample(100, [Self.chrome()], mode: .anc), Self.sample(105, [Self.chrome()], mode: .anc)]
        samples += stride(from: 50.0, through: 115, by: 5).map { Self.sample($0, [Self.chrome()], mode: .anc) }
        let out = Self.run(&rec, samples)
        #expect(out.activity.map(\.start) == [Self.t(100), Self.t(110)])
        #expect(out.activity.map(\.end) == [Self.t(110), Self.t(120)])
        #expect(out.noise.map(\.start) == [Self.t(100), Self.t(110)])
        #expect(out.noise.map(\.end) == [Self.t(110), Self.t(120)])
    }

    @Test func processesWhileDisconnectedAreIgnoredAndReconnectStartsAtTheWatermark() {
        var rec = Self.recorder()
        var outs = [rec.ingest(Self.sample(0, [Self.chrome()])), rec.ingest(Self.sample(5, [Self.chrome()]))]
        let closing = rec.ingest(Self.sample(7, [Self.chrome()], connected: false))
        #expect(closing.activity.map(\.end) == [Self.t(10)])
        outs.append(closing)
        outs += [rec.ingest(Self.sample(8, [Self.chrome()])), rec.flush()]
        let out = Self.merge(outs)
        #expect(out.activity.map(\.start) == [Self.t(0), Self.t(10)])
        #expect(out.activity.map(\.end) == [Self.t(10), Self.t(13)])
        #expect(rec.ingest(Self.sample(9, [Self.chrome()], connected: false)).isEmpty)
    }

    @Test func noiseIntervalsSplitAtLocalMidnight() {
        let midnight = Self.calendar().startOfDay(for: Self.base).addingTimeInterval(86_400)
        var rec = Self.recorder()
        var outs = stride(from: -10.0, through: 15.0, by: 5).map {
            rec.ingest(InsightsSample(time: midnight.addingTimeInterval($0), connected: true, noiseMode: .anc))
        }
        outs.append(rec.flush())
        let out = Self.merge(outs)
        #expect(out.noise.map(\.start) == [midnight.addingTimeInterval(-10), midnight])
        #expect(out.noise.map(\.end) == [midnight, midnight.addingTimeInterval(20)])
    }

    @Test func listeningToCallUpgradeKeepsBothKindsAndMayOverlap() {
        var rec = Self.recorder()
        // Plain upgrade: listening 0...10 then call 10...20, no overlap.
        let up = Self.run(&rec, [Self.sample(0, [Self.chrome()]), Self.sample(5, [Self.chrome()]),
                                 Self.sample(10, [Self.chrome(input: true)]), Self.sample(15, [Self.chrome(input: true)])])
        #expect(up.activity.map(\.kind) == [.listening, .call])
        #expect(up.activity.map(\.start) == [Self.t(0), Self.t(10)])
        #expect(up.activity.map(\.end) == [Self.t(10), Self.t(20)])
        // Flicker back within the merge gap: the keys are independent, so the intervals overlap by design.
        var rec2 = Self.recorder()
        let flick = Self.run(&rec2, [Self.sample(0, [Self.chrome()]), Self.sample(5, [Self.chrome(input: true)]),
                                     Self.sample(10, [Self.chrome()])])
        #expect(flick.activity.map(\.kind) == [.listening, .call])
        #expect(flick.activity.map(\.start) == [Self.t(0), Self.t(5)])
        #expect(flick.activity.map(\.end) == [Self.t(15), Self.t(10)])
    }

    @Test func duplicateBundleIDsInOneSampleAreDeduplicatedPerKind() {
        func proc(_ name: String?, out: Bool, input: Bool, route: AudioRoute = .bluetooth) -> ProcessActivity {
            ProcessActivity(bundleID: "com.x", appName: name, outputRunning: out, inputRunning: input, route: route)
        }
        // First non-nil name wins, first route wins.
        var rec = Self.recorder()
        let a = Self.run(&rec, [Self.sample(0, [proc("First", out: true, input: false), proc("Second", out: true, input: false, route: .usb)])])
        #expect(a.activity.count == 1); #expect(a.activity[0].appName == "First"); #expect(a.activity[0].route == .bluetooth)
        // A missing name is filled in from a later duplicate.
        var rec2 = Self.recorder()
        let b = Self.run(&rec2, [Self.sample(0, [proc(nil, out: true, input: false), proc("Second", out: true, input: false)])])
        #expect(b.activity.map(\.appName) == ["Second"])
        // Flags are judged per process, never OR'd: output-only + input-only is listening, not a call.
        var rec3 = Self.recorder()
        let c = Self.run(&rec3, [Self.sample(0, [proc("A", out: true, input: false), proc("A", out: false, input: true)])])
        #expect(c.activity.map(\.kind) == [.listening])
    }

    @Test func equalTimestampsDoNotDuplicateOrLengthenActivity() {
        var rec = Self.recorder()
        let out = Self.run(&rec, [Self.sample(0, [Self.chrome()]), Self.sample(0, [Self.chrome()])])
        #expect(out.activity.map(\.start) == [Self.t(0)]); #expect(out.activity.map(\.end) == [Self.t(5)])
    }

    @Test func intervalsSplitAtLocalMidnightAndAcrossDST() {
        // UTC: 23:59:50 -> 00:00:20
        let midnight = Self.calendar().startOfDay(for: Self.base).addingTimeInterval(86_400)
        var rec = Self.recorder()
        let samples = stride(from: -10.0, through: 15.0, by: 5).map {
            InsightsSample(time: midnight.addingTimeInterval($0), processes: [Self.chrome()], connected: true)
        }
        var outs = samples.map { rec.ingest($0) }; outs.append(rec.flush())
        let out = Self.merge(outs)
        #expect(out.activity.count == 2)
        #expect(out.activity[0].end == midnight); #expect(out.activity[1].start == midnight)
        #expect(out.activity[1].end == midnight.addingTimeInterval(20))

        // America/New_York 2026-03-08 is 23 hours long.
        let ny = Self.calendar("America/New_York")
        var comps = DateComponents(); comps.year = 2026; comps.month = 3; comps.day = 8
        let dayStart = ny.date(from: comps)!
        let nextDay = ny.startOfDay(for: dayStart.addingTimeInterval(30 * 3600))
        #expect(nextDay.timeIntervalSince(dayStart) == 23 * 3600)
        var nyRec = InsightsRecorder(calendar: ny)
        var nyOuts: [RecorderOutput] = []
        for off in stride(from: -10.0, through: 10.0, by: 5) {
            nyOuts.append(nyRec.ingest(InsightsSample(time: nextDay.addingTimeInterval(off), processes: [Self.chrome()], connected: true)))
        }
        nyOuts.append(nyRec.flush())
        let nyOut = Self.merge(nyOuts)
        #expect(nyOut.activity.count == 2)
        #expect(nyOut.activity[0].end == nextDay)

        // A long interval starting on the 23-hour DST day is cut at the real local midnight.
        var long = InsightsRecorder(tick: 12 * 3600, calendar: ny)
        _ = long.ingest(InsightsSample(time: dayStart.addingTimeInterval(20 * 3600), processes: [Self.chrome()], connected: true))
        let slices = long.flush().activity
        #expect(slices.count == 2)
        #expect(slices[0].start == dayStart.addingTimeInterval(20 * 3600)); #expect(slices[0].end == nextDay)
        #expect(slices[1].start == nextDay); #expect(slices[1].end == dayStart.addingTimeInterval(32 * 3600))
    }

    @Test func noiseIntervalsFollowModeChangesAndSkipUnknown() {
        var rec = Self.recorder()
        let out = Self.run(&rec, [Self.sample(0, mode: .anc), Self.sample(5, mode: .anc), Self.sample(10, mode: .transparency),
                                  Self.sample(15, mode: nil), Self.sample(20, mode: .off)])
        #expect(out.noise.map(\.mode) == [.anc, .transparency, .off])
        #expect(out.noise.map(\.start) == [Self.t(0), Self.t(10), Self.t(20)])
        #expect(out.noise.map(\.end) == [Self.t(10), Self.t(15), Self.t(25)])
    }

    @Test func activityRecordsTheNoiseModeAtItsStart() {
        var rec = Self.recorder()
        let out = Self.run(&rec, [Self.sample(0, [Self.chrome()], mode: .anc), Self.sample(5, [Self.chrome()], mode: .off)])
        #expect(out.activity.first?.noiseMode == .anc)
    }

    @Test func batteryReadingsOnChangeOrEveryTenMinutes() {
        var rec = Self.recorder()
        var readings: [BatteryReading] = []
        for (s, p) in [(0.0, 80), (5, 80), (10, 79), (15, 79)] { readings += rec.ingest(Self.sample(s, battery: p)).battery }
        #expect(readings.map(\.percent) == [80, 79])
        // same value is re-recorded after batteryEvery (samples kept within 2*tick so no gap reset)
        var long = InsightsRecorder(tick: 5, mergeGap: 10, batteryEvery: 20, calendar: Self.calendar())
        var r2: [BatteryReading] = []
        for s in stride(from: 0.0, through: 45, by: 5) { r2 += long.ingest(Self.sample(s, battery: 50)).battery }
        #expect(r2.map(\.time) == [Self.t(0), Self.t(20), Self.t(40)])
        // unknown battery or disconnected produces nothing
        #expect(rec.ingest(Self.sample(20, battery: nil)).battery.isEmpty)
        #expect(rec.ingest(Self.sample(25, connected: false, battery: 10)).battery.isEmpty)
    }

    @Test func excludedAppsAreNeverRecorded() {
        var rec = Self.recorder(excluded: ["com.google.Chrome"])
        var outs = [rec.ingest(Self.sample(0, [Self.chrome()])), rec.ingest(Self.sample(5, [Self.chrome()]))]
        rec.excluded = []
        outs += [rec.ingest(Self.sample(10, [Self.chrome()])), rec.ingest(Self.sample(15, [Self.chrome()])), rec.flush()]
        let out = Self.merge(outs)
        #expect(out.activity.count == 1)
        #expect(out.activity[0].start == Self.t(10)); #expect(out.activity[0].end == Self.t(20))
    }

    @Test func flushClosesOpenIntervals() {
        var rec = Self.recorder()
        #expect(rec.ingest(Self.sample(0, [Self.chrome()], mode: .anc)).isEmpty == true)
        let out = rec.flush()
        #expect(out.activity.map(\.end) == [Self.t(5)])
        #expect(out.noise.map(\.end) == [Self.t(5)])
        #expect(rec.flush().isEmpty)
    }

    @Test func noZeroLengthIntervalsEver() {
        var rec = Self.recorder()
        let out = Self.run(&rec, [Self.sample(0, [Self.chrome()], mode: .anc), Self.sample(0, [Self.chrome()], mode: .off),
                                  Self.sample(2, [Self.chrome()], mode: .anc)])
        for i in out.activity { #expect(i.end > i.start) }
        for i in out.noise { #expect(i.end > i.start) }
    }
}
