import Foundation
import GaiaProtocol

/// The fixed, read-only command lists the probe sends. Nothing else is ever sent.
public enum ProbePlan {
    private static func read(_ command: UInt16, _ payload: [UInt8] = []) -> GaiaFrame {
        GaiaFrame(vendor: GaiaVendor.sennheiser, command: command, payload: Data(payload))
    }

    public static func initial() -> [GaiaFrame] {
        [read(0x1201), read(0x1206)]
    }

    public static func afterFirmware(_ fw: FirmwareVersion) -> [GaiaFrame] {
        var frames = [
            read(0x0603), read(0x0602), read(0x0800), read(0x0804), read(0x1A05),
            read(0x1805), read(0x1801), read(0x1A01), read(0x1A03), read(0x0806),
            read(0x0601, [0x00]), read(0x0802), read(0x1400), read(0x1407), read(0x1409),
        ]
        if fw >= FirmwareVersion(3, 12, 0) {
            frames.append(read(0x081A))
        }
        // Below 3.16.4 the 10xx ids mean writes on the older EQ generation: never sent there.
        if fw >= FirmwareVersion(3, 16, 4) {
            frames += [read(0x1000), read(0x1003, [0x00]), read(0x1009)]
            frames += (UInt8(0)...4).map { read(0x100B, [$0]) }
            frames += (UInt8(0)...4).map { read(0x1002, [$0]) }
        }
        return frames
    }

    public static func pairedEntries(count: UInt16) -> [GaiaFrame] {
        (0..<UInt8(min(count, 8))).flatMap { [read(0x1401, [$0]), read(0x1404, [$0])] }
    }
}
