import Foundation
import GaiaProtocol
import HeadsetCore

/// Mutable device state behind `SimulatedHeadset`.
public struct SimulatedState: Sendable {
    public var firmware: FirmwareVersion
    public var modelID: String
    public var battery: UInt8
    public var charging: [UInt8]
    public var codec: UInt8
    public var audioMode: UInt16
    public var ancEnabled: Bool
    public var transparencyEnabled: Bool
    public var pauseInTransparency: Bool
    public var noiseModeTable: [UInt8]
    public var noiseLevel: UInt8
    public var sidetone: UInt8
    public var autoPowerOff: [UInt8]
    public var voicePrompts: UInt8
    public var sampleRate: UInt32
    public var eq1Params: [Int16: Int16]
    public var eq1LevelShiftX10: Int8
    public var eq1KnobY: UInt16

    /// Values from the Phase 0 capture of the ACCENTUM (firmware 3.12.14).
    public static let accentumProbed: SimulatedState = {
        let flat = try? EQGen1.encode(.accentum, gains: [0, 0, 0, 0, 0], bassBoost: false)
        var params: [Int16: Int16] = [:]
        if let w = flat?.params, let n = w.first {
            for i in 0..<Int(n) where 2 + 2 * i < w.count { params[w[1 + 2 * i]] = w[2 + 2 * i] }
        }
        return SimulatedState(
            firmware: FirmwareVersion(3, 12, 14), modelID: "ACAEBT SE", battery: 20, charging: [0, 0],
            codec: 1, audioMode: 1, ancEnabled: true, transparencyEnabled: false, pauseInTransparency: true,
            noiseModeTable: [1, 0, 2, 0, 3, 0], noiseLevel: 0, sidetone: 1, autoPowerOff: [0, 0, 0],
            voicePrompts: 2, sampleRate: 44100, eq1Params: params, eq1LevelShiftX10: 0, eq1KnobY: 0x4000)
    }()
}

/// In-memory `HeadsetTransport` that answers GAIA requests from `SimulatedState`.
public actor SimulatedHeadset: HeadsetTransport {
    public nonisolated let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var deframer = GaiaDeframer()
    private var silent: Set<UInt16> = []
    private var ignoreWrites: Set<UInt16> = []
    private var sendLimit: Int?
    private var sendCount = 0

    public private(set) var state: SimulatedState
    public private(set) var sent: [GaiaFrame] = []

    public init(state: SimulatedState = .accentumProbed) {
        self.state = state
        (incoming, continuation) = AsyncStream.makeStream(of: Data.self)
    }

    /// Test hook: mutate the device state directly.
    public func update(_ mutate: @Sendable (inout SimulatedState) -> Void) { mutate(&state) }
    public func setSilent(_ commands: Set<UInt16>) { silent = commands }
    public func setIgnoreWrites(_ commands: Set<UInt16>) { ignoreWrites = commands }
    public func failSends(after count: Int) { sendLimit = count; sendCount = 0 }

    public func open() async throws {}
    public func close() async { continuation.finish() }

    public func send(_ data: Data) async throws {
        if let limit = sendLimit, sendCount >= limit { throw TransportError.notOpen }
        sendCount += 1
        for frame in deframer.append(data) {
            sent.append(frame)
            guard !silent.contains(frame.command) else { continue }
            let reply = respond(to: frame)
            if let bytes = try? reply.encoded() { continuation.yield(bytes) }
        }
    }

    // MARK: Command handling

    private func ok(_ f: GaiaFrame, _ payload: [UInt8] = []) -> GaiaFrame {
        GaiaFrame(vendor: f.vendor, command: f.command | 0x0100, payload: Data(payload))
    }
    private func fail(_ f: GaiaFrame, code: UInt8 = 0x01) -> GaiaFrame {
        GaiaFrame(vendor: f.vendor, command: f.command | 0x0180, payload: Data([code]))
    }
    private func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }

    private var gen1Supported: Bool {
        state.firmware >= FirmwareVersion(2, 12, 0) && state.firmware < FirmwareVersion(3, 16, 4)
    }

    private func respond(to f: GaiaFrame) -> GaiaFrame {
        let p = Array(f.payload)
        let isWrite = Self.writes.contains(f.command)
        if isWrite, ignoreWrites.contains(f.command) { return ok(f) }
        let b: (Bool) -> UInt8 = { $0 ? 1 : 0 }
        switch f.command {
        case 0x1201:
            let v = state.firmware
            return ok(f, be16(v.major) + be16(v.minor) + be16(v.patch))
        case 0x1206: return ok(f, Array(state.modelID.utf8) + [0])
        case 0x0603: return ok(f, [state.battery])
        case 0x0602: return ok(f, state.charging)
        case 0x0800: return ok(f, [state.codec])
        case 0x0804: return ok(f, be16(state.audioMode))
        case 0x1A05: return ok(f, [b(state.ancEnabled)])
        case 0x1805: return ok(f, [b(state.transparencyEnabled)])
        case 0x1801: return ok(f, [b(state.pauseInTransparency)])
        case 0x1A01: return ok(f, state.noiseModeTable)
        case 0x1A03: return ok(f, [state.noiseLevel])
        case 0x0806: return ok(f, [state.sidetone])
        case 0x0601: return ok(f, state.autoPowerOff)
        case 0x0802: return ok(f, [state.voicePrompts])
        case 0x081A:
            let r = state.sampleRate
            return ok(f, [UInt8(r >> 24), UInt8((r >> 16) & 0xFF), UInt8((r >> 8) & 0xFF), UInt8(r & 0xFF)])
        // Observed on the real ACCENTUM (2026-11-11): after a single `1804 [01]` from ANC on, the device
        // read ANC = 1 AND transparency = 1. The two switches are independent; no mutual exclusion.
        case 0x1A04: guard let v = p.first else { return fail(f) }; state.ancEnabled = v != 0; return ok(f)
        case 0x1804: guard let v = p.first else { return fail(f) }; state.transparencyEnabled = v != 0; return ok(f)
        case 0x1800: guard let v = p.first else { return fail(f) }; state.pauseInTransparency = v != 0; return ok(f)
        case 0x0803:
            guard p.count == 2 else { return fail(f) }
            state.audioMode = UInt16(p[0]) << 8 | UInt16(p[1])
            return ok(f)
        case 0x1002, 0x1003, 0x1004, 0x1005, 0x1006, 0x1007:
            guard gen1Supported else { return fail(f) }
            return respondGen1(f, p)
        default: return fail(f)
        }
    }

    private static let writes: Set<UInt16> = [0x1A04, 0x1804, 0x1800, 0x0803, 0x1006, 0x1004, 0x1002]

    private func respondGen1(_ f: GaiaFrame, _ p: [UInt8]) -> GaiaFrame {
        switch f.command {
        case 0x1002:
            let w = EQGen1.words(f.payload)
            guard let n = w.first, n >= 0, w.count >= 1 + 2 * Int(n) else { return fail(f) }
            for i in 0..<Int(n) { state.eq1Params[w[1 + 2 * i]] = w[2 + 2 * i] }
            return ok(f)
        case 0x1003:
            let w = EQGen1.words(f.payload)
            guard let n = w.first, n >= 0, w.count >= 1 + 2 * Int(n) else { return fail(f) }
            var out: [Int16] = [n]
            for i in 0..<Int(n) { let id = w[1 + 2 * i]; out += [id, state.eq1Params[id] ?? 0] }
            return ok(f, Array(EQGen1.payload(out)))
        case 0x1004:
            guard p.count >= 4, p[0] == 0, p[1] == 1 else { return fail(f, code: 5) }
            state.eq1KnobY = UInt16(p[2]) << 8 | UInt16(p[3])
            return ok(f)
        case 0x1005:
            guard p.count >= 2, p[0] == 0, p[1] == 1 else { return fail(f, code: 5) }
            return ok(f, be16(state.eq1KnobY))
        case 0x1006:
            guard let v = p.first else { return fail(f) }
            state.eq1LevelShiftX10 = Int8(bitPattern: v)
            return ok(f)
        default: // 0x1007
            return ok(f, [UInt8(bitPattern: state.eq1LevelShiftX10)])
        }
    }
}
