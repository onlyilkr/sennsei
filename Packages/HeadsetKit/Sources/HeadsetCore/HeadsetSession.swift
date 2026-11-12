import Foundation
import GaiaProtocol

/// The one place that talks to a headset on behalf of the app.
///
/// Guarantees:
/// - every outgoing frame passes `CommandCatalog.validate`; a refused frame is never sent;
/// - nothing is written while connecting (the catalog is used in read-only mode until the profile is known);
/// - every write is read back, and a failed step stops the remaining writes;
/// - one operation at a time, and a late reply to a timed-out request is never taken for a later one.
public actor HeadsetSession {
    private enum Outcome { case reply(GaiaFrame), timeout, closed }

    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<Outcome, Never>
        let timer: Task<Void, Never>
    }

    private let transport: any HeadsetTransport
    private let catalog: CommandCatalog
    private let replyTimeout: Duration
    private let allowUnverifiedWrites: Bool

    private var current: HeadsetState?
    private var firmware: FirmwareVersion?
    private var reader: Task<Void, Never>?
    private var generation = 0

    // Operation lock (FIFO).
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    // Reply matching: at most one request is outstanding.
    private var expecting: UInt32?
    private var inbox: GaiaFrame?
    private var waiter: Waiter?
    private var nextWaiterID = 0
    private var consecutiveTimeouts = 0

    public init(
        transport: any HeadsetTransport, catalog: CommandCatalog = .standard,
        replyTimeout: Duration = .milliseconds(1500), allowUnverifiedWrites: Bool = false
    ) {
        self.transport = transport
        self.catalog = catalog
        self.replyTimeout = replyTimeout
        self.allowUnverifiedWrites = allowUnverifiedWrites
    }

    public var state: HeadsetState? { current }

    // MARK: Public API

    public func connect() async throws(SessionError) -> HeadsetState {
        await acquire()
        defer { release() }
        if let current { return current }

        do { try await transport.open() } catch let e as TransportError {
            throw .transport(e)
        } catch { throw .transport(.openFailed(-1)) }

        startReader()
        do {
            return try await readInitialState()
        } catch {
            await teardown()
            throw error
        }
    }

    public func disconnect() async {
        await teardown()
    }

    public func readEQ() async throws(SessionError) -> EQSnapshot {
        await acquire()
        defer { release() }
        return try await readEQLocked()
    }

    public func writeEQ(gains: [Double], bassBoost: Bool) async throws(SessionError) -> EQSnapshot {
        await acquire()
        defer { release() }
        guard let profile = current?.profile else { throw .notConnected }
        guard profile.isWritable else { throw .unsupported("read-only model") }
        guard profile.eq == .gen1, let params = profile.eqParams else { throw .unsupported("equalizer") }

        // Out-of-range gains are refused up front (encode would silently clamp them).
        guard gains.allSatisfy({ $0.isFinite && $0 >= params.minGain && $0 <= params.maxGain }) else {
            throw .unsupported("equalizer gains")
        }
        // The user-EQ mode switch is only sent when the current mode is known and differs.
        guard let currentMode = current?.audioMode else { throw .unsupported("audio mode unknown") }

        let encoded: EQGen1Encoded
        do { encoded = try EQGen1.encode(params, gains: gains, bassBoost: bassBoost) } catch {
            throw .unsupported("equalizer gains")
        }
        let frames = EQGen1.writeFrames(encoded)
        let modeFrame = GaiaFrame(vendor: GaiaVendor.sennheiser, command: 0x0803, payload: Data([0x00, 0x01]))
        let needsMode = currentMode != 1

        // Gate everything that may be sent before the first byte goes out.
        for frame in frames + (needsMode ? [modeFrame] : []) { _ = try gate(frame) }

        // From here on writes may have reached the device: a failure before a successful read-back
        // leaves the affected state unknown (nil) instead of stale. A read-back mismatch keeps the
        // device-read value.
        var modeSent = false
        var modeConfirmed = false
        do throws(SessionError) {
            for frame in frames { _ = try await exchange(frame) }

            var modeMismatch = false
            if needsMode {
                modeSent = true
                _ = try await exchange(modeFrame)
                let mode = try await exchange(Self.request(0x0804))
                let value = try Self.u16(mode, "audioMode")
                modeConfirmed = true
                current?.audioMode = value
                modeMismatch = value != 1
            }

            let snapshot = try await readEQLocked()
            let wanted = gains
            let matches: Bool
            if let read = snapshot.gains, read.count == wanted.count {
                matches = zip(read, wanted).allSatisfy { abs($0 - $1) <= 0.11 + 1e-9 }
            } else {
                matches = false
            }
            let exact = snapshot.levelShiftX10 == encoded.levelShiftX10 && snapshot.knobY == encoded.knobY
            if !matches || !exact || snapshot.bassBoost != bassBoost { throw .readBackMismatch("equalizer") }
            // Documented name: a user-EQ mode switch (0803) that 0804 does not confirm.
            if modeMismatch { throw .readBackMismatch("audio mode") }
            return snapshot
        } catch {
            if case .readBackMismatch = error { throw error }
            current?.eq = nil
            if modeSent && !modeConfirmed { current?.audioMode = nil }
            throw error
        }
    }

    public func setANC(_ on: Bool) async throws(SessionError) {
        await acquire()
        defer { release() }
        guard let profile = current?.profile else { throw .notConnected }
        guard profile.isWritable else { throw .unsupported("read-only model") }

        let write = GaiaFrame(vendor: GaiaVendor.sennheiser, command: 0x1A04, payload: Data([on ? 1 : 0]))
        do throws(SessionError) {
            _ = try await exchange(write)
            let reply = try await exchange(Self.request(0x1A05))
            let value = try Self.byte(reply, "ancEnabled") != 0
            current?.ancEnabled = value
            if value != on { throw .readBackMismatch("anc") }
        } catch {
            switch error {
            case .readBackMismatch, .rejected: throw error   // state is device-read / nothing was sent
            default:
                current?.ancEnabled = nil
                throw error
            }
        }
    }

    /// Sets "pause music when Transparency starts": one `1800 [pause ? 01 : 00]` write, read back with
    /// `1801`. The write is always sent (the caller refreshes first and decides whether it is needed).
    /// A read-back that differs keeps the device-read value; any other failure once the write was
    /// sent leaves the field unknown (nil).
    public func setPauseInTransparency(_ pause: Bool) async throws(SessionError) {
        await acquire()
        defer { release() }
        guard let profile = current?.profile else { throw .notConnected }
        guard profile.isWritable else { throw .unsupported("read-only model") }

        let write = GaiaFrame(vendor: GaiaVendor.sennheiser, command: 0x1800, payload: Data([pause ? 1 : 0]))
        _ = try gate(write)   // refuse before the first byte goes out
        do throws(SessionError) {
            _ = try await exchange(write)
            let reply = try await exchange(Self.request(0x1801))
            let value = try Self.byte(reply, "pauseInTransparency") != 0
            current?.pauseInTransparency = value
            if value != pause { throw .readBackMismatch("pause in transparency") }
        } catch {
            switch error {
            case .readBackMismatch, .rejected: throw error   // state is device-read / nothing was sent
            default:
                current?.pauseInTransparency = nil
                throw error
            }
        }
    }

    /// Re-reads the status fields (reads only, never writes). A field whose read fails with a device
    /// error or one timeout becomes nil (unknown).
    public func refreshStatus() async throws(SessionError) -> HeadsetState {
        await acquire()
        defer { release() }
        guard var state = current else { throw .notConnected }
        state.battery = try await optional(0x0603) { $0.payload.first }
        state.charging = try await optional(0x0602) { f in
            f.payload.count >= 2 ? f.payload[f.payload.startIndex + 1] != 0 : nil
        }
        state.codec = try await optional(0x0800) { $0.payload.first }
        state.ancEnabled = try await optional(0x1A05) { $0.payload.first.map { $0 != 0 } }
        state.transparencyEnabled = try await optional(0x1805) { $0.payload.first.map { $0 != 0 } }
        state.audioMode = try await optional(0x0804) { f in
            f.payload.count >= 2 ? UInt16(f.payload[f.payload.startIndex]) << 8 | UInt16(f.payload[f.payload.startIndex + 1]) : nil
        }
        state.pauseInTransparency = try await optional(0x1801) { $0.payload.first.map { $0 != 0 } }
        // The link may have been torn down while reading; do not resurrect the state.
        guard reader != nil, current != nil else { throw .notConnected }
        current = state
        return state
    }

    /// Sets the noise mode. The headset keeps ANC on when transparency is turned on (observed on the
    /// device: both flags can be 1), so the switches are driven separately:
    /// - `.transparency`: `1804 [01]` unless transparency is already on;
    /// - `.anc`: `1804 [00]` if transparency is on (the ANC switch is left alone; a read-back mismatch
    ///   reports it if ANC then reads off), else `1A04 [01]` if ANC is off, else nothing;
    /// - `.off`: `1804 [00]` if transparency is on, then `1A04 [00]` if ANC is on (UNVERIFIED on hardware).
    /// All writes happen inside this one operation (lock held, no other frames in between).
    public func setNoiseMode(_ mode: NoiseMode) async throws(SessionError) {
        await acquire()
        defer { release() }
        guard let profile = current?.profile else { throw .notConnected }
        guard profile.isWritable else { throw .unsupported("read-only model") }

        if current?.ancEnabled == nil || current?.transparencyEnabled == nil {
            try await readNoiseSwitches()
        }
        guard let anc = current?.ancEnabled, let transparency = current?.transparencyEnabled else {
            throw .unsupported("noise mode unknown")
        }
        var plan: [(command: UInt16, value: UInt8)] = []
        switch mode {
        case .transparency:
            if !transparency { plan = [(0x1804, 1)] }
        case .anc:
            if transparency { plan = [(0x1804, 0)] } else if !anc { plan = [(0x1A04, 1)] }
        case .off:
            if transparency { plan.append((0x1804, 0)) }
            if anc { plan.append((0x1A04, 0)) }
        }
        if plan.isEmpty { return }

        let writes = plan.map {
            GaiaFrame(vendor: GaiaVendor.sennheiser, command: $0.command, payload: Data([$0.value]))
        }
        for write in writes { _ = try gate(write) }   // refuse before the first byte goes out
        do throws(SessionError) {
            for write in writes { _ = try await exchange(write) }
            try await readNoiseSwitches()
            if current?.noiseMode != mode { throw .readBackMismatch("noise control") }
        } catch {
            switch error {
            case .readBackMismatch, .rejected: throw error   // state is device-read / nothing was sent
            default:
                current?.ancEnabled = nil
                current?.transparencyEnabled = nil
                throw error
            }
        }
    }

    private func readNoiseSwitches() async throws(SessionError) {
        let anc = try await exchange(Self.request(0x1A05))
        let transparency = try await exchange(Self.request(0x1805))
        let a = try Self.byte(anc, "ancEnabled") != 0
        let t = try Self.byte(transparency, "transparencyEnabled") != 0
        current?.ancEnabled = a
        current?.transparencyEnabled = t
    }

    // MARK: Connect

    private func readInitialState() async throws(SessionError) -> HeadsetState {
        let fw = try await exchange(Self.request(0x1201))
        guard let version = FirmwareVersion(payload: fw.payload) else {
            throw .unsupported("firmware version reply")
        }
        firmware = version
        let model = try await exchange(Self.request(0x1206))
        let modelID = String(decoding: model.payload.prefix { $0 != 0 }, as: UTF8.self)

        var state = HeadsetState(profile: CapabilityProfile(modelID: modelID, firmware: version))
        state.battery = try await optional(0x0603) { $0.payload.first }
        state.ancEnabled = try await optional(0x1A05) { $0.payload.first.map { $0 != 0 } }
        state.transparencyEnabled = try await optional(0x1805) { $0.payload.first.map { $0 != 0 } }
        state.audioMode = try await optional(0x0804) { f in
            f.payload.count >= 2 ? UInt16(f.payload[f.payload.startIndex]) << 8 | UInt16(f.payload[f.payload.startIndex + 1]) : nil
        }
        current = state
        return state
    }

    /// A status read that may fail without failing the connection (device error or one timeout).
    private func optional<T>(_ command: UInt16, _ parse: (GaiaFrame) -> T?) async throws(SessionError) -> T? {
        do { return parse(try await exchange(Self.request(command))) } catch {
            switch error {
            case .device, .timeout: return nil
            default: throw error
            }
        }
    }

    // MARK: EQ read

    private func readEQLocked() async throws(SessionError) -> EQSnapshot {
        guard let profile = current?.profile else { throw .notConnected }
        guard profile.eq == .gen1, let params = profile.eqParams else { throw .unsupported("equalizer") }

        var replies: [GaiaFrame] = []
        for frame in EQGen1.readFrames() { replies.append(try await exchange(frame)) }

        guard replies[0].payload.count == 1 else { throw .unsupported("malformed reply: eq1LevelShift") }
        let levelShift = Int8(bitPattern: replies[0].payload[replies[0].payload.startIndex])
        let knobY = try Self.u16(replies[1], "eq1Knob")
        let gainResponse = EQGen1.words(replies[2].payload)
        let filterTypes = EQGen1.words(replies[3].payload)

        let boost = EQGen1.bassBoost(fromKnobY: knobY)
        let unconfigured = EQGen1.isUnconfigured(filterTypes: filterTypes)
        var gains: [Double]?
        if let boost, !unconfigured {
            gains = EQGen1.decode(params, levelShiftX10: levelShift, bassBoost: boost, gainResponse: gainResponse)
        }
        let snapshot = EQSnapshot(
            firmware: profile.firmware.description, levelShiftX10: levelShift, knobY: knobY,
            gainResponse: gainResponse, filterTypes: filterTypes, gains: gains,
            bassBoost: boost, isUnconfigured: unconfigured)
        current?.eq = snapshot
        return snapshot
    }

    // MARK: Request / reply

    private static func request(_ command: UInt16) -> GaiaFrame {
        GaiaFrame(vendor: GaiaVendor.sennheiser, command: command, payload: Data())
    }

    private static func byte(_ f: GaiaFrame, _ what: String) throws(SessionError) -> UInt8 {
        guard let b = f.payload.first else { throw .unsupported("malformed reply: \(what)") }
        return b
    }

    private static func u16(_ f: GaiaFrame, _ what: String) throws(SessionError) -> UInt16 {
        guard f.payload.count >= 2 else { throw .unsupported("malformed reply: \(what)") }
        let s = f.payload.startIndex
        return UInt16(f.payload[s]) << 8 | UInt16(f.payload[s + 1])
    }

    private static func key(_ vendor: UInt16, _ command: UInt16) -> UInt32 { UInt32(vendor) << 16 | UInt32(command) }

    /// The catalog spec that applies to `frame` for the known firmware (for names and access).
    private func applicableSpec(_ frame: GaiaFrame) -> CommandSpec? {
        let all = catalog.specs(vendor: frame.vendor, id: frame.command)
        if let blocked = all.first(where: { $0.status == .blocked }) { return blocked }
        let covering = all.first { spec in
            guard let firmware else { return spec.minFirmware == nil && spec.maxFirmwareExclusive == nil }
            if let min = spec.minFirmware, firmware < min { return false }
            if let max = spec.maxFirmwareExclusive, firmware >= max { return false }
            return true
        }
        return covering ?? all.first
    }

    private func name(of frame: GaiaFrame) -> String {
        applicableSpec(frame)?.name ?? String(format: "0x%04X", frame.command)
    }

    /// The single gate: catalog validation, plus a hard stop for writes to read-only models.
    private func gate(_ frame: GaiaFrame) throws(SessionError) -> CommandSpec? {
        // Until the profile is known (connecting) only reads can pass.
        let mode: SendMode = current == nil ? .readOnly : .readWrite
        do {
            try catalog.validate(frame, firmware: firmware, mode: mode, allowUnverifiedWrites: allowUnverifiedWrites)
        } catch { throw .rejected(error) }
        let spec = applicableSpec(frame)
        if spec?.access == .set, current?.profile.isWritable != true { throw .unsupported("read-only model") }
        return spec
    }

    private func exchange(_ frame: GaiaFrame) async throws(SessionError) -> GaiaFrame {
        guard reader != nil else { throw .notConnected }
        _ = try gate(frame)
        let name = name(of: frame)
        let bytes: Data
        do { bytes = try frame.encoded() } catch { throw .unsupported("frame too large") }

        let key = Self.key(frame.vendor, frame.command)
        expecting = key
        inbox = nil
        do { try await transport.send(bytes) } catch {
            expecting = nil
            if let e = error as? TransportError { throw .transport(e) }
            throw .transport(.writeFailed(-1))
        }

        let outcome: Outcome
        if let early = inbox {
            inbox = nil
            outcome = .reply(early)
        } else if reader == nil {
            outcome = .closed
        } else {
            outcome = await withCheckedContinuation { continuation in
                nextWaiterID += 1
                let id = nextWaiterID
                let timeout = replyTimeout
                let timer = Task { [weak self] in
                    try? await Pause.sleep(timeout)
                    await self?.expire(id)
                }
                waiter = Waiter(id: id, continuation: continuation, timer: timer)
            }
        }
        expecting = nil

        switch outcome {
        case .reply(let reply):
            consecutiveTimeouts = 0
            if reply.kind == .error { throw .device(command: name, code: reply.payload.first ?? 0) }
            return reply
        case .timeout:
            consecutiveTimeouts += 1
            if consecutiveTimeouts >= 3 {
                await teardown()
                throw .linkDead
            }
            // Grace window: keep the operation lock for one more timeout while `expecting == nil`.
            // A late answer to this request arrives with nothing expecting it and is ignored; the
            // next request (queued on the lock) cannot be sent, so cannot be answered by it, until
            // the window is over. That held lock plus `expecting == nil` is the whole protection.
            try? await Pause.sleep(replyTimeout)
            throw .timeout(name)
        case .closed:
            await teardown()
            throw .linkDead
        }
    }

    private func expire(_ id: Int) {
        guard let w = waiter, w.id == id else { return }
        waiter = nil
        w.continuation.resume(returning: .timeout)
    }

    private func receive(_ frames: [GaiaFrame]) {
        for frame in frames where frame.kind == .response || frame.kind == .error {
            let key = Self.key(frame.vendor, frame.baseCommand)
            guard key == expecting else { continue }
            if let w = waiter {
                waiter = nil
                expecting = nil
                w.timer.cancel()
                w.continuation.resume(returning: .reply(frame))
            } else if inbox == nil {
                inbox = frame
            }
        }
    }

    private func streamEnded(_ gen: Int) async {
        guard gen == generation, reader != nil else { return }
        await teardown()
    }

    // MARK: Lifecycle

    private func startReader() {
        generation += 1
        let gen = generation
        let stream = transport.incoming
        consecutiveTimeouts = 0
        inbox = nil
        expecting = nil
        firmware = nil
        reader = Task { [weak self] in
            var deframer = GaiaDeframer()
            for await chunk in stream {
                if Task.isCancelled { return }
                await self?.receive(deframer.append(chunk))
            }
            await self?.streamEnded(gen)
        }
    }

    private func teardown() async {
        generation += 1
        let task = reader
        reader = nil
        task?.cancel()
        current = nil
        firmware = nil
        if let w = waiter {
            waiter = nil
            w.timer.cancel()
            w.continuation.resume(returning: .closed)
        }
        expecting = nil
        inbox = nil
        await transport.close()
    }

    // MARK: Operation lock

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { queue.append($0) }
    }

    private func release() {
        if queue.isEmpty { busy = false } else { queue.removeFirst().resume() }
    }
}
