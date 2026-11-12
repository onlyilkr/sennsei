import Foundation
import HeadsetCore
import HeadsetBluetooth

// Read-only probe: opens the RFCOMM control channel, runs ProbeRunner, writes a JSONL log.
// Launch through Tools/probe/run_probe.sh (the Bluetooth permission belongs to the .app bundle).

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func describe(_ error: TransportError, deviceName: String) -> String {
    switch error {
    case .deviceNotFound:
        "Headphones named '\(deviceName)' not found among paired devices. Check the Bluetooth permission for SennseiProbe and the exact device name (override with SENNSEI_DEVICE_NAME)."
    case .bluetoothUnavailable:
        "Bluetooth is off or unavailable on this Mac. Turn it on and retry."
    case .deviceNotConnected:
        "'\(deviceName)' is paired but not connected. Connect the headphones to this Mac and retry."
    case .openTimedOut:
        "Opening the control channel timed out. Check that the headphones are on and in range, and that no other app holds the channel."
    case .openFailed(let status):
        "Opening the control channel failed (IOReturn \(status)). Check the headphones are connected and retry."
    case .gaiaServiceNotFound:
        "The headphones do not advertise the GAIA control service."
    case .notOpen:
        "The control channel is not open."
    case .writeFailed(let status):
        "Writing to the control channel failed (IOReturn \(status))."
    }
}

// MARK: EQ Gen1 verification modes

struct EQ1WriteRecord: Codable {
    let firmware: String
    let requestedGains: [Double]
    let requestedBassBoost: Bool
    let before: EQSnapshot
    let after: EQSnapshot
}

func timestamp() -> String {
    let stamp = DateFormatter()
    stamp.locale = Locale(identifier: "en_US_POSIX")
    stamp.dateFormat = "yyyyMMdd-HHmmss"
    return stamp.string(from: Date())
}

func compact(_ s: EQSnapshot) -> String {
    let gains = s.gains.map { "[" + $0.map { String(format: "%.1f", $0) }.joined(separator: ", ") + "]" } ?? "unknown"
    let bass = s.bassBoost.map { $0 ? "true" : "false" } ?? "unknown"
    return "\(gains) bass=\(bass)\(s.isUnconfigured ? " (unconfigured)" : "")"
}

func loadSnapshot(_ environment: [String: String]) -> EQSnapshot {
    guard let path = environment["SENNSEI_EQ_SNAPSHOT"], !path.isEmpty else {
        fail("SENNSEI_EQ_SNAPSHOT (path to an eq1-snapshot-*.json) is required. Nothing was connected or sent.", code: 1)
    }
    guard let data = FileManager.default.contents(atPath: path) else {
        fail("Cannot read the snapshot file at \(path). Nothing was connected or sent.", code: 1)
    }
    guard let snapshot = try? JSONDecoder().decode(EQSnapshot.self, from: data) else {
        fail("\(path) is not a valid EQSnapshot JSON file. Nothing was connected or sent.", code: 1)
    }
    return snapshot
}

func shellQuote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func describeSession(_ error: SessionError) -> String {
    switch error {
    case .timeout(let step): "timeout at step \(step)"
    case .readBackMismatch(let what): "readBackMismatch(\(what))"
    case .device(let command, let code): "device error \(code) on \(command)"
    case .transport(let t): describe(t, deviceName: "the headphones")
    case .linkDead: "the connection to the headphones was lost"
    default: "\(error)"
    }
}

func describe(_ error: EQVerificationError, deviceName: String) -> String {
    switch error {
    case .missingSnapshot: "A snapshot is required."
    case .snapshotFirmwareMismatch(let snap, let dev): "The snapshot is from firmware \(snap) but the headphones run \(dev)."
    case .badGains(let text): "Bad SENNSEI_EQ_GAINS '\(text)': expected five comma-separated numbers, e.g. 0,0,0,0,0."
    case .session(.transport(let t)): describe(t, deviceName: deviceName)
    case .session(let e): describeSession(e)
    }
}

/// Writes a result file. On failure prints the JSON to stdout instead and returns false. Never exits.
@discardableResult
func writeJSON<T: Encodable>(_ value: T, prefix: String) -> Bool {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value) else {
        FileHandle.standardError.write(Data("Could not encode \(prefix).\n".utf8))
        return false
    }
    do {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Sennsei/probe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "\(prefix)-\(timestamp()).json")
        try data.write(to: file, options: .withoutOverwriting)
        print("Wrote \(file.path)")
        return true
    } catch {
        FileHandle.standardError.write(Data("Could not write the \(prefix) file (\(error)); printing it to stdout instead.\n".utf8))
        FileHandle.standardOutput.write(data)
        print("")
        return false
    }
}

@MainActor
func runEQ1(mode: String, environment: [String: String], deviceName: String) async -> Never {
    // 1. Validate all inputs; nothing Bluetooth-related has been created yet.
    var snapshot: EQSnapshot?
    var gains: [Double] = []
    var bass = false
    if mode != "eq1-read" {
        snapshot = loadSnapshot(environment)
    }
    if mode == "eq1-write" {
        guard let text = environment["SENNSEI_EQ_GAINS"], !text.isEmpty else {
            fail("SENNSEI_EQ_GAINS (five comma-separated numbers) is required. Nothing was connected or sent.", code: 1)
        }
        do { gains = try EQVerification.parseGains(text) } catch {
            fail(describe(error, deviceName: deviceName) + " Nothing was connected or sent.", code: 1)
        }
        switch environment["SENNSEI_EQ_BASS"] ?? "0" {
        case "0", "": bass = false
        case "1": bass = true
        case let other: fail("Bad SENNSEI_EQ_BASS '\(other)': use 0 or 1. Nothing was connected or sent.", code: 1)
        }
    }

    // 2. Only now build the transport and session. eq1-read cannot write: unverified writes stay off.
    let transport = RFCOMMTransport(deviceName: deviceName)
    let session = HeadsetSession(transport: transport, allowUnverifiedWrites: mode != "eq1-read")
    do {
        let state = try await session.connect()
        print("Connected, firmware \(state.profile.firmware)")
        print("audio mode: \(state.audioMode.map { String($0) } ?? "unknown")")
    } catch {
        await session.disconnect()
        fail(describe(.session(error), deviceName: deviceName) + " Nothing was written.", code: 1)
    }

    // Every path below disconnects before it exits.
    var ok = true
    var before: EQSnapshot?
    var mayHaveWritten = false
    do {
        switch mode {
        case "eq1-read":
            let snap = try await EQVerification.read(session)
            print("eq: \(compact(snap))")
            ok = writeJSON(snap, prefix: "eq1-snapshot")
        case "eq1-write":
            before = try await EQVerification.read(session)
            mayHaveWritten = true
            let r = try await EQVerification.write(session, gains: gains, bassBoost: bass, snapshot: snapshot)
            print("before: \(compact(r.before))")
            print("after: \(compact(r.after))")
            ok = writeJSON(EQ1WriteRecord(firmware: r.after.firmware, requestedGains: gains, requestedBassBoost: bass, before: r.before, after: r.after), prefix: "eq1-write")
        default:
            mayHaveWritten = true
            let after = try await EQVerification.restore(session, snapshot: snapshot)
            if let snapshot { print("snapshot: \(compact(snapshot))") }
            print("after: \(compact(after))")
            ok = writeJSON(after, prefix: "eq1-restore")
        }
    } catch {
        var message = describe(error, deviceName: deviceName)
        if case .snapshotFirmwareMismatch = error { mayHaveWritten = false }
        if mayHaveWritten {
            message += "\nThe headphones' equalizer (and possibly the audio mode) may have been partially written."
            message += "\nRestore with: SENNSEI_MODE=eq1-restore SENNSEI_EQ_SNAPSHOT=\(shellQuote(environment["SENNSEI_EQ_SNAPSHOT"] ?? "<snapshot path>")) Tools/probe/run_probe.sh"
            if let before, writeJSON(before, prefix: "eq1-before") == false {
                message += "\n(The pre-write state could not be saved to a file; it was printed above.)"
            }
        } else {
            message += "\nNothing was written."
        }
        FileHandle.standardError.write(Data((message + "\n").utf8))
        ok = false
    }
    await session.disconnect()
    exit(ok ? 0 : 1)
}

Task { @MainActor in
    let environment = ProcessInfo.processInfo.environment
    let deviceName = environment["SENNSEI_DEVICE_NAME"] ?? "ACCENTUM"
    let mode = environment["SENNSEI_MODE"] ?? ""

    // Validate the mode and every input BEFORE any Bluetooth object exists.
    let knownModes: Set<String> = ["", "dump-sdp", "eq1-read", "eq1-write", "eq1-restore"]
    if !knownModes.contains(mode) { fail("Unknown SENNSEI_MODE '\(mode)'", code: 1) }

    if mode.hasPrefix("eq1-") {
        await runEQ1(mode: mode, environment: environment, deviceName: deviceName)
    }

    let transport = RFCOMMTransport(deviceName: deviceName)

    // Diagnostic mode: SDP query only. No connection, no RFCOMM channel, no GAIA command.
    if environment["SENNSEI_MODE"] == "dump-sdp" {
        let text: String
        do {
            text = try await transport.dumpSDPRecords()
        } catch {
            fail((error as? TransportError).map { describe($0, deviceName: deviceName) } ?? "SDP dump failed: \(error)", code: 1)
        }
        do {
            let directory = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/Sennsei/probe", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            let file = directory.appending(path: "sdp-dump-\(stamp.string(from: Date())).txt")
            try Data(text.utf8).write(to: file, options: .withoutOverwriting)
            print("Wrote SDP dump to \(file.path)")
        } catch {
            FileHandle.standardError.write(Data("Could not write the dump (\(error)); printing it to stdout instead.\n".utf8))
            print(text)
        }
        exit(0)
    }

    do {
        try await transport.open()
    } catch {
        var message = (error as? TransportError).map { describe($0, deviceName: deviceName) }
            ?? "Could not open the headphones: \(error)"
        if error as? TransportError == .gaiaServiceNotFound {
            let seen = transport.lastSeenRecords
                .map { "(\($0.serviceUUIDs.joined(separator: ","))) channel \($0.rfcommChannel.map(String.init) ?? "none")" }
                .joined(separator: "; ")
            message += " SDP records seen: \(seen.isEmpty ? "none" : seen)."
        }
        fail(message, code: 1)
    }

    let runner = ProbeRunner(transport: transport)
    let result: (firmware: FirmwareVersion, records: [ProbeRecord])
    do {
        result = try await runner.run()
    } catch ProbeError.noReplyOnControlChannel {
        let bytes = await runner.receivedByteCount()
        if bytes > 0 {
            fail("Bytes arrived (\(bytes)) but none parsed as GAIA frames.", code: 2)
        }
        fail("No reply on the control channel. Close Smart Control on your phone and retry.", code: 2)
    } catch {
        fail("Probe failed: \(error)", code: 1)
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var output = Data()
    do {
        for record in result.records {
            output.append(try encoder.encode(record))
            output.append(0x0A)
        }
    } catch {
        fail("Could not encode the log: \(error)", code: 1)
    }

    do {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Sennsei/probe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fw = result.firmware
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let file = directory.appending(path: "accentum-\(fw.major).\(fw.minor).\(fw.patch)-\(stamp.string(from: Date())).jsonl")
        try output.write(to: file, options: .withoutOverwriting)
        print("Wrote \(result.records.count) records to \(file.path)")
    } catch {
        // Never discard a capture: fall back to stdout so the records survive.
        FileHandle.standardError.write(Data("Could not write the log (\(error)); printing it to stdout instead.\n".utf8))
        FileHandle.standardOutput.write(output)
    }
    exit(0)
}
RunLoop.main.run()
