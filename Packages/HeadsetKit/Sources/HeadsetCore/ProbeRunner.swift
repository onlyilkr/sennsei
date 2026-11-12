import Foundation
import GaiaProtocol

/// One line of the probe's JSONL output.
public struct ProbeRecord: Codable, Equatable, Sendable {
    public let tx: String
    public let rx: [String]
    public let ms: Int
    public let note: String

    public init(tx: String, rx: [String], ms: Int, note: String) {
        self.tx = tx
        self.rx = rx
        self.ms = ms
        self.note = note
    }
}

public enum ProbeError: Error, Equatable {
    case noReplyOnControlChannel
}

/// Sends the `ProbePlan` read-only commands one at a time and records every reply.
/// The transport must already be open; the runner always closes it before returning or throwing.
public struct ProbeRunner: Sendable {
    private let transport: any HeadsetTransport
    private let catalog: CommandCatalog
    private let replyTimeout: Duration
    private let gap: Duration
    private let byteCounter = ByteCounter()

    /// Raw bytes received from the transport so far (content is never stored).
    public func receivedByteCount() async -> Int { await byteCounter.total }

    public init(
        transport: any HeadsetTransport,
        catalog: CommandCatalog = .standard,
        replyTimeout: Duration = .seconds(3),
        gap: Duration = .milliseconds(150)
    ) {
        self.transport = transport
        self.catalog = catalog
        self.replyTimeout = replyTimeout
        self.gap = gap
    }

    public func run() async throws -> (firmware: FirmwareVersion, records: [ProbeRecord]) {
        let mailbox = Mailbox()
        let reader = Task { [transport, byteCounter] in
            var deframer = GaiaDeframer()
            for await chunk in transport.incoming {
                await byteCounter.add(chunk.count)
                await mailbox.add(deframer.append(chunk))
            }
        }
        defer { reader.cancel() }
        do {
            let result = try await execute(mailbox)
            await transport.close()
            return result
        } catch {
            await transport.close()
            throw error
        }
    }

    private func execute(_ mailbox: Mailbox) async throws -> (firmware: FirmwareVersion, records: [ProbeRecord]) {
        var records: [ProbeRecord] = []
        let initial = ProbePlan.initial()

        let (first, firstReply) = try await exchange(initial[0], firmware: nil, mailbox)
        records.append(first)
        guard let firstReply, let firmware = FirmwareVersion(payload: firstReply.payload) else {
            throw ProbeError.noReplyOnControlChannel
        }

        // A transport failure after the firmware is known (device switched away, Mac sleep) keeps the
        // records collected so far. Cancellation and catalog errors are not TransportErrors and still throw.
        do {
            for frame in initial.dropFirst() + ProbePlan.afterFirmware(firmware) {
                let (record, reply) = try await exchange(frame, firmware: firmware, mailbox)
                records.append(record)
                if frame.command == 0x1400, let reply, reply.payload.count >= 2 {
                    let count = UInt16(reply.payload[reply.payload.startIndex]) << 8
                        | UInt16(reply.payload[reply.payload.startIndex + 1])
                    for entry in ProbePlan.pairedEntries(count: count) {
                        records.append(try await exchange(entry, firmware: firmware, mailbox).0)
                    }
                }
            }
        } catch let error as TransportError {
            records.append(ProbeRecord(tx: "", rx: [], ms: 0, note: "aborted: \(error)"))
        }
        return (firmware, records)
    }

    /// Validates (read-only), sends, waits for the matching reply, then collects notifications during the gap.
    private func exchange(
        _ frame: GaiaFrame, firmware: FirmwareVersion?, _ mailbox: Mailbox
    ) async throws -> (ProbeRecord, GaiaFrame?) {
        let name = catalog.spec(vendor: frame.vendor, id: frame.command)?.name
            ?? String(format: "0x%04X", frame.command)
        let bytes = try frame.encoded()
        let tx = Self.hex(bytes)

        do {
            try catalog.validate(frame, firmware: firmware, mode: .readOnly)
        } catch {
            return (ProbeRecord(tx: tx, rx: [], ms: 0, note: "\(name) rejected: \(error)"), nil)
        }

        let clock = ContinuousClock()
        let start = clock.now
        try await transport.send(bytes)

        var received: [GaiaFrame] = []
        var reply: GaiaFrame?
        let deadline = start + replyTimeout
        while reply == nil {
            received += await mailbox.drain()
            reply = received.first {
                $0.vendor == frame.vendor && $0.baseCommand == frame.command && ($0.kind == .response || $0.kind == .error)
            }
            if reply != nil || clock.now >= deadline { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        if gap > .zero { try await Task.sleep(for: gap) }
        received += await mailbox.drain()

        let elapsed = clock.now - start
        let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        let rx = received.compactMap { Self.storedHex($0) }
        let record = ProbeRecord(tx: tx, rx: rx, ms: ms, note: reply == nil ? "\(name) timeout" : name)
        return (record, reply)
    }

    /// Pairing replies may hold Bluetooth addresses and phone names: keep the header and the first
    /// 3 payload bytes, mask the rest ("**") so the length survives. Only the stored record is redacted.
    private static func storedHex(_ frame: GaiaFrame) -> String? {
        guard let bytes = try? frame.encoded() else { return nil }
        let plain = hex(bytes)
        guard frame.vendor == GaiaVendor.sennheiser, frame.baseCommand == 0x1401 || frame.baseCommand == 0x1404 else {
            return plain
        }
        let keep = GaiaFrame.headerLength + 3
        return hex(bytes.prefix(keep)) + String(repeating: "**", count: max(0, bytes.count - keep))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

private actor ByteCounter {
    private(set) var total = 0
    func add(_ n: Int) { total += n }
}

private actor Mailbox {
    private var frames: [GaiaFrame] = []
    func add(_ new: [GaiaFrame]) { frames += new }
    func drain() -> [GaiaFrame] {
        defer { frames.removeAll() }
        return frames
    }
}
