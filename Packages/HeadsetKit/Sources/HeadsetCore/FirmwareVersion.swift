import Foundation

public struct FirmwareVersion: Comparable, Sendable, CustomStringConvertible {
    public let major: UInt16
    public let minor: UInt16
    public let patch: UInt16

    public init(_ major: UInt16, _ minor: UInt16, _ patch: UInt16) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses a firmware-version response payload: three big-endian u16 values.
    public init?(payload: Data) {
        let b = Array(payload)
        guard b.count >= 6 else { return nil }
        self.init(
            UInt16(b[0]) << 8 | UInt16(b[1]),
            UInt16(b[2]) << 8 | UInt16(b[3]),
            UInt16(b[4]) << 8 | UInt16(b[5])
        )
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (l: FirmwareVersion, r: FirmwareVersion) -> Bool {
        (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
    }
}
