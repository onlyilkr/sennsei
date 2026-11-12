import Foundation

public enum GaiaVendor {
    public static let sennheiser: UInt16 = 0x0495
    public static let qualcomm: UInt16 = 0x001D
}

public enum GaiaError: Error, Equatable {
    case payloadTooLarge(Int)
}

public enum GaiaKind: Sendable {
    case command, notification, response, error
}

/// A GAIA v3 frame: `FF 03 00 <len> <vendor BE> <command BE> <payload>`.
public struct GaiaFrame: Equatable, Sendable {
    public static let startByte: UInt8 = 0xFF
    public static let version: UInt8 = 0x03
    public static let headerLength = 8
    public static let maxPayloadLength = 254

    public var vendor: UInt16
    public var command: UInt16
    public var payload: Data

    public init(vendor: UInt16, command: UInt16, payload: Data) {
        self.vendor = vendor
        self.command = command
        self.payload = payload
    }

    /// Bits 7-8 of the command carry the frame kind.
    public var kind: GaiaKind {
        switch (command >> 7) & 0x3 {
        case 0: .command
        case 1: .notification
        case 2: .response
        default: .error
        }
    }

    public var baseCommand: UInt16 { command & ~0x0180 }

    public func encoded() throws(GaiaError) -> Data {
        guard payload.count <= Self.maxPayloadLength else {
            throw .payloadTooLarge(payload.count)
        }
        var out = Data([Self.startByte, Self.version, 0x00, UInt8(payload.count)])
        out.append(UInt8(vendor >> 8))
        out.append(UInt8(vendor & 0xFF))
        out.append(UInt8(command >> 8))
        out.append(UInt8(command & 0xFF))
        out.append(payload)
        return out
    }
}
