import Foundation
import IOBluetooth
import HeadsetCore

/// RFCOMM transport over IOBluetooth. Hardware only; exercised by the probe, not by unit tests.
///
/// - Never calls `openConnection()`: a headset connected elsewhere must not be pulled away.
/// - `close()` closes only the RFCOMM channel, never the baseband connection (it would cut audio).
/// - IOBluetooth calls back on the main run loop, hence `@MainActor`.
@MainActor
public final class RFCOMMTransport: NSObject, HeadsetTransport {
    public nonisolated let incoming: AsyncStream<Data>
    private nonisolated let continuation: AsyncStream<Data>.Continuation

    private let deviceName: String
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    public private(set) var channelID: UInt8?
    /// The SDP records of the last query, kept so a caller can report them when no GAIA service is found.
    public private(set) var lastSeenRecords: [SDPRecordSummary] = []

    private var sdpContinuation: CheckedContinuation<IOReturn, Never>?
    private var openContinuation: CheckedContinuation<IOReturn, Error>?
    private var sdpTimer: Task<Void, Never>?
    private var openTimer: Task<Void, Never>?
    private var isOpening = false

    private static let sdpTimeout: Duration = .seconds(10)
    private static let openTimeout: Duration = .seconds(8)
    private static let serviceClassIDList: BluetoothSDPServiceAttributeID = 0x0001

    public init(deviceName: String) {
        self.deviceName = deviceName
        (incoming, continuation) = AsyncStream<Data>.makeStream()
        super.init()
    }

    // MARK: HeadsetTransport

    public func open() async throws {
        // A second concurrent open() must not overwrite the first one's continuations.
        guard !isOpening, channel == nil else { throw TransportError.openFailed(kIOReturnBusy) }
        isOpening = true
        defer { isOpening = false }
        let device = try connectedDevice()
        self.device = device

        let sdpStatus = await runSDPQuery(on: device)
        guard sdpStatus == kIOReturnSuccess else { throw TransportError.openFailed(sdpStatus) }
        let records = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
        lastSeenRecords = records.map(Self.summary(of:))
        let id = try GaiaServiceLocator.channel(in: lastSeenRecords)
        channelID = id

        do {
            let status = try await openChannel(on: device, id: id)
            guard status == kIOReturnSuccess else { throw TransportError.openFailed(status) }
        } catch {
            discardChannel()
            throw error
        }
    }

    /// Closes the (possibly half-open) RFCOMM channel, detaches self as delegate and forgets it.
    /// Channel only; never the baseband connection.
    private func discardChannel() {
        guard let channel else { return }
        self.channel = nil
        _ = channel.setDelegate(nil)
        channel.close()
    }

    public func close() async {
        // Channel only; closeConnection() would cut the audio link.
        discardChannel()
        continuation.finish()
    }

    public func send(_ data: Data) async throws {
        guard let channel else { throw TransportError.notOpen }
        var bytes = [UInt8](data)
        let status = bytes.withUnsafeMutableBytes { buffer in
            channel.writeSync(buffer.baseAddress, length: UInt16(buffer.count))
        }
        guard status == kIOReturnSuccess else { throw TransportError.writeFailed(status) }
    }

    // MARK: SDP

    /// Finds the paired device by name and requires it to be connected already.
    /// Deliberately no openConnection(): only attach to an already-connected device.
    private func connectedDevice() throws -> IOBluetoothDevice {
        guard IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON else {
            throw TransportError.bluetoothUnavailable
        }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        guard let device = paired.first(where: { $0.name == deviceName }) else {
            throw TransportError.deviceNotFound
        }
        guard device.isConnected() else { throw TransportError.deviceNotConnected }
        return device
    }

    /// Diagnostic: runs the same SDP query as `open()` and returns a raw-structure text dump.
    /// Opens no channel and sends nothing.
    public func dumpSDPRecords() async throws -> String {
        let device = try connectedDevice()
        let status = await runSDPQuery(on: device)
        guard status == kIOReturnSuccess else { throw TransportError.openFailed(status) }
        let records = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
        return SDPDumpFormatter.format(records.enumerated().map { Self.dump(of: $1, index: $0) })
    }

    private static let dumpedAttributes: [(BluetoothSDPServiceAttributeID, String)] = [
        (0x0000, "ServiceRecordHandle"), (0x0001, "ServiceClassIDList"),
        (0x0004, "ProtocolDescriptorList"), (0x0100, "ServiceName"),
    ]

    private static func dump(of record: IOBluetoothSDPServiceRecord, index: Int) -> SDPRecordDump {
        var channel: BluetoothRFCOMMChannelID = 0
        let hasChannel = record.getRFCOMMChannelID(&channel) == kIOReturnSuccess
        let keys = record.attributes?
            .keys.compactMap { ($0 as? NSNumber)?.uint16Value }.sorted()
        let attributes = dumpedAttributes.map { id, name in
            SDPAttributeDump(
                attributeID: id, name: name,
                element: record.getAttributeDataElement(id).map { describe($0, includeString: id == 0x0100) })
        }
        return SDPRecordDump(index: index, rfcommChannel: hasChannel ? channel : nil, attributeKeys: keys, attributes: attributes)
    }

    private static func hex(_ uuid: IOBluetoothSDPUUID?) -> String? {
        uuid.map { ($0 as Data).map { String(format: "%02x", $0) }.joined() }
    }

    private static func describe(_ element: IOBluetoothSDPDataElement, includeString: Bool, depth: Int = 0) -> SDPElementDescription {
        let array = element.getArrayValue() as NSArray?
        let uuid = element.getUUIDValue()
        var description = SDPElementDescription(
            typeDescriptor: element.getTypeDescriptor(), sizeDescriptor: element.getSizeDescriptor(),
            arrayCount: array?.count, arrayType: array.map { String(describing: type(of: $0)) },
            hasUUID: uuid != nil, uuid16Hex: hex(uuid?.getWithLength(16)),
            uuid4Hex: hex(uuid?.getWithLength(4)), uuid2Hex: hex(uuid?.getWithLength(2)),
            number: (element.getNumberValue() as NSNumber?).map { "\($0)" },
            string: includeString ? element.getStringValue() : nil,
            dataLength: (element.getDataValue() as Data?)?.count,
            valueDescription: (element.getValue() as AnyObject?).map { String(describing: $0) })
        if depth < 8 {
            description.children = (array as? [Any] ?? []).compactMap { $0 as? IOBluetoothSDPDataElement }
                .map { describe($0, includeString: includeString, depth: depth + 1) }
        }
        return description
    }


    private func runSDPQuery(on device: IOBluetoothDevice) async -> IOReturn {
        await withCheckedContinuation { (cont: CheckedContinuation<IOReturn, Never>) in
            sdpContinuation = cont
            let start = device.performSDPQuery(self)
            if start != kIOReturnSuccess { finishSDP(start); return }
            sdpTimer = Task { [weak self] in
                try? await Pause.sleep(Self.sdpTimeout)
                guard !Task.isCancelled else { return }
                self?.finishSDP(kIOReturnTimeout)
            }
        }
    }

    private func finishSDP(_ status: IOReturn) {
        sdpTimer?.cancel()
        sdpTimer = nil
        sdpContinuation?.resume(returning: status)
        sdpContinuation = nil
    }

    @objc(sdpQueryComplete:status:)
    func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        finishSDP(status)
    }

    private static func summary(of record: IOBluetoothSDPServiceRecord) -> SDPRecordSummary {
        let shape = record.getAttributeDataElement(serviceClassIDList).map(shape(of:))
        let uuids = SDPServiceClass.uuidStrings(from: shape)
        var channel: BluetoothRFCOMMChannelID = 0
        let hasChannel = record.getRFCOMMChannelID(&channel) == kIOReturnSuccess
        return SDPRecordSummary(serviceUUIDs: uuids, rfcommChannel: hasChannel ? channel : nil)
    }

    /// macOS may return a bare UUID element (not a sequence) for ServiceClassIDList.
    /// IOBluetoothSDPUUID is an NSData subclass; widen to the full 128-bit form first.
    private static func shape(of element: IOBluetoothSDPDataElement) -> SDPElementShape {
        if let uuid = element.getUUIDValue()?.getWithLength(16) { return .uuid(uuid as Data) }
        if let list = element.getArrayValue() as? [IOBluetoothSDPDataElement] {
            return .sequence(list.map(shape(of:)))
        }
        return .other
    }

    // MARK: RFCOMM

    private func openChannel(on device: IOBluetoothDevice, id: UInt8) async throws -> IOReturn {
        var created: IOBluetoothRFCOMMChannel?
        let start = device.openRFCOMMChannelAsync(&created, withChannelID: id, delegate: self)
        channel = created  // tracked immediately so every failure path can close it
        guard start == kIOReturnSuccess else { throw TransportError.openFailed(start) }
        return try await withCheckedThrowingContinuation { cont in
            openContinuation = cont
            openTimer = Task { [weak self] in
                try? await Pause.sleep(Self.openTimeout)
                guard !Task.isCancelled else { return }
                self?.finishOpen(.failure(TransportError.openTimedOut))
            }
        }
    }

    private func finishOpen(_ result: Result<IOReturn, Error>) {
        openTimer?.cancel()
        openTimer = nil
        openContinuation?.resume(with: result)
        openContinuation = nil
    }

    @objc(rfcommChannelOpenComplete:status:)
    func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        finishOpen(.success(status))
    }

    @objc(rfcommChannelData:data:length:)
    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data: UnsafeMutableRawPointer!, length: Int) {
        continuation.yield(Data(bytes: data, count: length))
    }

    @objc(rfcommChannelClosed:)
    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        self.channel = nil
        continuation.finish()
    }
}
