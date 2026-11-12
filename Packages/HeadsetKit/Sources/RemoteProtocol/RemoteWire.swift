import Foundation

/// Line-delimited JSON framing shared by the app and the command-line client.
public enum RemoteWire {
    public static let maxLineBytes = 4096

    /// One line of JSON with sorted keys, ending in a single newline.
    public static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data =
            (try? encoder.encode(value))
            ?? Data(#"{"error":{"code":"failed","message":"encoding failed"},"ok":false}"#.utf8)
        data.append(0x0A)
        return data
    }

    /// Decodes one line (a trailing newline is allowed); oversized, multi-line or malformed input gives nil.
    public static func decodeLine<T: Decodable>(_ line: Data) -> T? {
        var body = Data(line)
        while let last = body.last, last == 0x0A || last == 0x0D { body.removeLast() }
        guard !body.isEmpty, body.count <= maxLineBytes, !body.contains(0x0A) else { return nil }
        return try? JSONDecoder().decode(T.self, from: body)
    }
}
