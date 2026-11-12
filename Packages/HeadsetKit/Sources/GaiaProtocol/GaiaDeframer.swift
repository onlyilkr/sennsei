import Foundation

/// Reassembles GAIA frames from an arbitrarily chunked byte stream.
public struct GaiaDeframer: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append(_ data: Data) -> [GaiaFrame] {
        buffer.append(contentsOf: data)
        var frames: [GaiaFrame] = []
        let header = GaiaFrame.headerLength

        while true {
            guard let start = buffer.firstIndex(of: GaiaFrame.startByte) else {
                buffer.removeAll()
                break
            }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= header else { break }

            guard buffer[1] == GaiaFrame.version, buffer[2] == 0x00 else {
                buffer.removeFirst()
                continue
            }
            let total = header + Int(buffer[3])
            guard buffer.count >= total else { break }

            frames.append(GaiaFrame(
                vendor: UInt16(buffer[4]) << 8 | UInt16(buffer[5]),
                command: UInt16(buffer[6]) << 8 | UInt16(buffer[7]),
                payload: Data(buffer[header..<total])
            ))
            buffer.removeFirst(total)
        }
        return frames
    }
}
