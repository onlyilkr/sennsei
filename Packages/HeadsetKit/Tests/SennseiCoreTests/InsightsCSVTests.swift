import Foundation
import Testing
@testable import SennseiCore

@Suite struct InsightsCSVTests {
    @Test func formulaPrefixesAreNeutralised() {
        for raw in ["=cmd", "+1", "-1", "@SUM", "\tx"] {
            #expect(InsightsCSV.field(raw).hasPrefix("'"), "\(raw)")
        }
        #expect(InsightsCSV.field("\rx") == "\"'\rx\"")
        #expect(InsightsCSV.field("Chrome") == "Chrome")
    }

    @Test func fieldsWithSeparatorsAreQuoted() {
        #expect(InsightsCSV.field("a,b") == "\"a,b\"")
        #expect(InsightsCSV.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(InsightsCSV.field("line1\nline2") == "\"line1\nline2\"")
        #expect(InsightsCSV.field("=1,2") == "\"'=1,2\"")
    }

    @Test func headerAndIsoTimes() {
        let start = Date(timeIntervalSince1970: 1_780_315_200)
        let interval = ActivityInterval(
            app: "com.x", appName: nil, kind: .call, route: .usb, noiseMode: .anc, start: start, end: start.addingTimeInterval(60))
        let csv = InsightsCSV.render([interval])
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines[0] == "start,end,app,app_name,kind,route,noise_mode")
        #expect(lines[1] == "2026-06-01T12:00:00Z,2026-06-01T12:01:00Z,com.x,,call,usb,anc")
    }
}
