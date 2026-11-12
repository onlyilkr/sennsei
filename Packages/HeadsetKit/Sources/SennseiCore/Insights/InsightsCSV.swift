import Foundation
import HeadsetCore

/// CSV rendering for the Insights export (RFC 4180 quoting plus spreadsheet formula-injection defence).
enum InsightsCSV {
    static let header = "start,end,app,app_name,kind,route,noise_mode"

    /// One field: a leading `=`, `+`, `-`, `@`, tab or carriage return gets a `'` prefix so spreadsheets
    /// never evaluate it, then the field is quoted when it holds a comma, quote or line break.
    static func field(_ value: String) -> String {
        var text = value
        if let first = text.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) {
            text = "'" + text
        }
        // Scalars, not Characters: "\r\n" is a single Character that equals neither "\r" nor "\n".
        if text.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            // Scalar-based: replacingOccurrences uses canonical equivalence and misses a quote that is
            // followed by a combining mark.
            var escaped = String.UnicodeScalarView()
            for scalar in text.unicodeScalars {
                if scalar == "\"" { escaped.append("\"") }
                escaped.append(scalar)
            }
            text = "\"" + String(escaped) + "\""
        }
        return text
    }

    static func makeFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }

    static func row(_ interval: ActivityInterval, formatter: ISO8601DateFormatter = makeFormatter()) -> String {
        [
            formatter.string(from: interval.start), formatter.string(from: interval.end), interval.app, interval.appName ?? "",
            interval.kind.rawValue, interval.route.rawValue, interval.noiseMode?.rawValue ?? "",
        ].map(field).joined(separator: ",")
    }

    static func render(_ intervals: [ActivityInterval]) -> String {
        let formatter = makeFormatter()
        return ([header] + intervals.map { row($0, formatter: formatter) }).joined(separator: "\r\n") + "\r\n"
    }
}
