import Foundation

/// Byte pipe to a headset. Implementations deliver raw GAIA bytes; framing lives in `GaiaProtocol`.
public protocol HeadsetTransport: Sendable {
    func open() async throws
    func close() async
    func send(_ data: Data) async throws
    var incoming: AsyncStream<Data> { get }
}

public enum TransportError: Error, Equatable {
    case bluetoothUnavailable
    case deviceNotFound
    case deviceNotConnected
    case gaiaServiceNotFound
    case openFailed(Int32)
    case openTimedOut
    case notOpen
    case writeFailed(Int32)
}
