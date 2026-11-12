import Foundation

/// Lightweight, IOBluetooth-free description of an SDP data element's shape.
public indirect enum SDPElementShape: Equatable, Sendable {
    /// A UUID element; the bytes are the full 128-bit form (16 bytes).
    case uuid(Data)
    case sequence([SDPElementShape])
    case other
}

/// Turns the ServiceClassIDList attribute (0x0001) into UUID strings.
/// macOS may return a bare UUID element instead of a sequence, so both shapes are handled.
public enum SDPServiceClass {
    public static func uuidStrings(from shape: SDPElementShape?) -> [String] {
        switch shape {
        case .uuid(let data):
            return [uuidString(from: data)]
        case .sequence(let elements):
            return elements.flatMap { element -> [String] in
                if case .uuid = element { return uuidStrings(from: element) }
                return []
            }
        case .other, nil:
            return []
        }
    }

    public static func uuidString(from data: Data) -> String {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        guard hex.count == 32 else { return hex }
        let c = Array(hex)
        func part(_ r: Range<Int>) -> String { String(c[r]) }
        return [part(0..<8), part(8..<12), part(12..<16), part(16..<20), part(20..<32)].joined(separator: "-")
    }
}
