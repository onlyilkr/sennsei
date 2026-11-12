import Foundation
import GaiaProtocol
import HeadsetCore
import HeadsetSimulator
import Testing

@testable import SennseiCore

@MainActor private func model(_ sim: SimulatedHeadset, poll: Duration = .seconds(3600)) -> AppModel {
    AppModel(makeTransport: { sim }, pollInterval: poll, replyTimeout: .milliseconds(80))
}

@MainActor @Test func startConnectsReadsStateAndWritesNothing() async throws {
    let sim = SimulatedHeadset(); let m = model(sim)
    await m.start()
    #expect(m.phase == .connected); #expect(m.state?.battery == 20); #expect(m.state?.noiseMode == .anc)
    let cmds = await sim.sent.map(\.command)
    #expect(cmds.allSatisfy { ![0x1A04, 0x1804, 0x1800, 0x0803, 0x1002, 0x1006, 0x1004].contains($0) })
    await m.stop()
}

@MainActor @Test func failedConnectShowsAMessageAndSendsNothing() async {
    let sim = SimulatedHeadset(); await sim.failSends(after: 0)
    let m = model(sim); await m.start()
    guard case .failed(let msg) = m.phase else { Issue.record("expected failure"); return }
    #expect(msg.key.hasPrefix("error."))
}

@MainActor @Test func noiseModeUpdatesOnlyAfterTheDeviceConfirms() async {
    let sim = SimulatedHeadset(); let m = model(sim); await m.start()
    await m.setNoiseMode(.transparency)
    #expect(m.state?.noiseMode == .transparency); #expect(m.lastError == nil); #expect(m.busy == false)
    await m.stop()
}

@MainActor @Test func failedNoiseWriteKeepsTheDeviceTruthAndReportsIt() async {
    let sim = SimulatedHeadset(); await sim.setIgnoreWrites([0x1804])
    let m = model(sim); await m.start()
    await m.setNoiseMode(.transparency)
    #expect(m.state?.noiseMode == .anc); #expect(m.lastError?.key == "error.readBack")
    await m.stop()
}

@MainActor @Test func rapidTogglesAreProcessedInOrderAndTheLastWins() async {
    let sim = SimulatedHeadset(); let m = model(sim); await m.start()
    // MainActor tasks start in creation order (`async let` children give no ordering guarantee: flaky).
    let a = Task { await m.setNoiseMode(.transparency) }
    let b = Task { await m.setNoiseMode(.off) }
    let c = Task { await m.setNoiseMode(.anc) }
    _ = await (a.value, b.value, c.value)
    #expect(m.state?.noiseMode == .anc); #expect(m.busy == false)
    let noise = await sim.sent.map(\.command).filter { $0 == 0x1A04 || $0 == 0x1804 }
    #expect(noise.count >= 2)                               // they were queued; frames did not interleave (one write each)
    await m.stop()
}

@MainActor @Test func presetWritesThroughTheSessionWhenAvailable() async throws {
    let sim = SimulatedHeadset(); let m = model(sim); await m.start()
    #expect(m.eqAvailability == .available)
    await m.applyPreset("Rock")
    #expect(m.selectedPreset == "Rock"); #expect(m.lastError == nil)
    let rock = try #require(EQPresetCatalog.presets.first { $0.name == "Rock" })
    let gains = try #require(m.state?.eq?.gains)
    for (a, b) in zip(gains, rock.gains) { #expect(abs(a - b) < 0.11) }
    await m.stop()
}

@MainActor @Test func eqIsExplainedNotAttemptedWhenAudioModeIsNotEqualizer() async {
    var st = SimulatedState.accentumProbed; st.audioMode = 3
    let sim = SimulatedHeadset(state: st); let m = model(sim); await m.start()
    #expect(m.eqAvailability == .audioModeNotEqualizer)
    let before = await sim.sent.count
    await m.applyPreset("Rock")
    // Only the read-only refresh goes out; no write.
    #expect(await sim.sent.dropFirst(before).map(\.command).allSatisfy { !eqWriteCommands.contains($0) })
    #expect(m.lastError?.key == "error.unsupported")
    await m.stop()
}

@MainActor @Test func gen2FirmwareAndReadOnlyModelsAreExplained() async {
    var g2 = SimulatedState.accentumProbed; g2.firmware = FirmwareVersion(3, 34, 0)
    let m1 = model(SimulatedHeadset(state: g2)); await m1.start()
    #expect(m1.eqAvailability == .unsupportedGeneration); await m1.stop()
    var m4 = SimulatedState.accentumProbed; m4.modelID = "M4AEBT Denim"
    let m2 = model(SimulatedHeadset(state: m4)); await m2.start()
    #expect(m2.eqAvailability == .readOnlyModel); await m2.stop()
}

@MainActor @Test func pollingRefreshesBatteryWithoutWriting() async throws {
    let sim = SimulatedHeadset(); let m = model(sim, poll: .milliseconds(60)); await m.start()
    await sim.update { $0.battery = 70 }
    try await Task.sleep(for: .milliseconds(250))
    #expect(m.state?.battery == 70)
    #expect(await sim.sent.map(\.command).filter { [0x1A04, 0x1804, 0x1002].contains($0) }.isEmpty)
    await m.stop()
}

@MainActor @Test func stopClosesTheSessionAndLaterActionsAreHarmless() async {
    let sim = SimulatedHeadset(); let m = model(sim); await m.start(); await m.stop()
    #expect(m.phase == .idle)
    await m.setNoiseMode(.off)                              // not connected: error message, no crash
    #expect(m.lastError?.key == "error.notConnected")
}

// MARK: Additional tests

@MainActor @Test func noiseModeRefreshesReadOnlyFirstThenWritesExactlyOnce() async {
    let sim = SimulatedHeadset(); let m = model(sim); await m.start()
    let before = await sim.sent.count
    await m.setNoiseMode(.transparency)
    let frames = await sim.sent.dropFirst(before).map(\.command)
    let writeIndexes = frames.indices.filter { [0x1A04, 0x1804].contains(frames[$0]) }
    #expect(writeIndexes.count == 1)
    #expect(frames[writeIndexes[0]] == 0x1804)
    // The refresh reads (battery first) all come before the write.
    #expect(frames.first == 0x0603)
    #expect(frames[..<writeIndexes[0]].contains(0x0603))
    #expect(m.state?.noiseMode == .transparency)
    await m.stop()
}

/// Three silent status reads make the session's link-dead rule fire during `refreshStatus`.
private let deadLink: Set<UInt16> = [0x0603, 0x0602, 0x0800]
private let writeCommands: Set<UInt16> = [0x1804, 0x1A04, 0x1800, 0x1002, 0x1006, 0x1004, 0x0803]
private let eqWriteCommands: Set<UInt16> = [0x1002, 0x1006, 0x1004, 0x0803]

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Forwards to a simulator but makes `open()` slow, to hold a start() in flight.
private struct SlowOpen: HeadsetTransport {
    let inner: SimulatedHeadset
    var incoming: AsyncStream<Data> { inner.incoming }
    func open() async throws { try await Task.sleep(for: .milliseconds(150)); try await inner.open() }
    func close() async { await inner.close() }
    func send(_ data: Data) async throws { try await inner.send(data) }
}

@MainActor @Test func aFailingRefreshReportsAndSendsNoWrite() async {
    let sim = SimulatedHeadset(); let m = model(sim); await m.start()
    await sim.setSilent(deadLink)   // the refresh dies (frames ARE recorded); a write would be recorded too
    let before = await sim.sent.count
    await m.setNoiseMode(.transparency)
    // Three timed-out reads => linkDead => SessionError.linkDead => "error.link".
    #expect(m.lastError?.key == "error.link")
    let after = await sim.sent.dropFirst(before).map(\.command)
    #expect(!after.isEmpty)
    #expect(after.allSatisfy { !writeCommands.contains($0) })
    await m.stop()
}

@MainActor @Test func presetAndBassAlsoRefreshFirstAndStayReadOnlyWhenItFails() async {
    let sim = SimulatedHeadset(); let m = model(sim); await m.start()
    await sim.setSilent(deadLink)
    let before = await sim.sent.count
    await m.applyPreset("Rock")
    #expect(m.lastError?.key == "error.link")
    #expect(await sim.sent.dropFirst(before).map(\.command).allSatisfy { !writeCommands.contains($0) })
    await m.stop()
}

@MainActor @Test func presetAndBassRefreshReadOnlyBeforeTheEQWrite() async {
    let sim = SimulatedHeadset(); let m = model(sim); await m.start()
    let before = await sim.sent.count
    await m.setBassBoost(true)
    #expect(m.lastError == nil)
    let frames = await sim.sent.dropFirst(before).map(\.command)
    let firstWrite = frames.firstIndex { eqWriteCommands.contains($0) }
    #expect(frames.first == 0x0603)
    #expect(firstWrite != nil && firstWrite! > 0)
    #expect(m.state?.eq?.bassBoost == true)
    await m.stop()
}

@MainActor @Test func unknownEQRefusesBassAndPresetAndSendsNothing() async {
    let sim = SimulatedHeadset(); let m = model(sim); await m.start()
    // A write that dies half way leaves the equalizer unknown (nil).
    await sim.failSends(after: 8)
    await m.applyPreset("Rock")
    #expect(m.lastError != nil)
    #expect(m.state?.eq == nil)
    // The automatic read-only EQ re-read also fails: 7 refresh reads go out, the 8th send throws.
    await sim.failSends(after: 7)
    let before = await sim.sent.count
    await m.setBassBoost(true)
    #expect(m.lastError?.key == "error.other")
    #expect(await sim.sent.dropFirst(before).map(\.command).allSatisfy { !writeCommands.contains($0) })
    await sim.failSends(after: 7)
    let mid = await sim.sent.count
    await m.applyPreset("Pop")
    #expect(m.lastError?.key == "error.other")
    #expect(await sim.sent.dropFirst(mid).map(\.command).allSatisfy { !writeCommands.contains($0) })
    await m.stop()
}

@MainActor @Test func selectedPresetFollowsTheDeviceNotTheRequest() async {
    let sim = SimulatedHeadset(); let m = model(sim); await m.start()
    await m.applyPreset("Rock")
    #expect(m.selectedPreset == "Rock")
    // A write that dies half way: the equalizer is unknown, so no preset may be claimed.
    await sim.failSends(after: 8)
    await m.applyPreset("Pop")
    #expect(m.selectedPreset == nil)
    await sim.failSends(after: 100_000)
    // A write the device ignores must not select the requested preset either.
    await m.applyPreset("Rock")
    await sim.setIgnoreWrites([0x1006, 0x1004, 0x1002])
    await m.applyPreset("Pop")
    #expect(m.selectedPreset != "Pop")
    await m.stop()
}

@MainActor @Test func phaseBecomesFailedWhenAnActionKillsTheLink() async {
    let sim = SimulatedHeadset(); let m = model(sim, poll: .milliseconds(60)); await m.start()
    await sim.setSilent(deadLink)
    await m.setNoiseMode(.transparency)
    #expect(m.phase == .failed(UserMessage(key: "error.link")))
    #expect(m.state == nil)
    let count = await sim.sent.count
    try? await Task.sleep(for: .milliseconds(300))
    #expect(await sim.sent.count == count)   // polling stopped
    await m.stop()
}

@MainActor @Test func startTwiceKeepsOneSession() async {
    let sim = SimulatedHeadset(); let counter = Counter()
    let m = AppModel(makeTransport: { counter.bump(); return sim }, pollInterval: .milliseconds(60), replyTimeout: .milliseconds(80))
    async let a: Void = m.start()
    async let b: Void = m.start()
    _ = await (a, b)
    await m.start()
    #expect(counter.value == 1)
    #expect(m.phase == .connected)
    await m.stop()
}

@MainActor @Test func startAfterFailureReplacesTheSession() async {
    // A closed simulator cannot be reopened (its stream is finished), so each session gets its own.
    let first = SimulatedHeadset(); let second = SimulatedHeadset(); let counter = Counter()
    let m = AppModel(makeTransport: { counter.bump(); return counter.value == 1 ? first : second },
                     pollInterval: .milliseconds(60), replyTimeout: .milliseconds(80))
    await m.start()
    await first.setSilent(deadLink)
    await m.setNoiseMode(.off)
    #expect(m.phase == .failed(UserMessage(key: "error.link")))
    await m.start()
    #expect(m.phase == .connected); #expect(counter.value == 2)
    #expect(m.state?.battery == 20)
    await m.stop()
}

@MainActor @Test func stopDuringStartWins() async throws {
    let sim = SimulatedHeadset()
    let m = AppModel(makeTransport: { SlowOpen(inner: sim) }, pollInterval: .milliseconds(60), replyTimeout: .milliseconds(80))
    let starting = Task { await m.start() }
    try await Task.sleep(for: .milliseconds(40))
    #expect(m.phase == .connecting)
    await m.stop()
    await starting.value
    #expect(m.phase == .idle); #expect(m.state == nil)
    let count = await sim.sent.count
    try await Task.sleep(for: .milliseconds(300))
    #expect(await sim.sent.count == count)   // no polling on a disconnected session
    #expect(m.phase == .idle)
}

@MainActor @Test func stopLeavesNoPolling() async throws {
    let sim = SimulatedHeadset(); let m = model(sim, poll: .milliseconds(60)); await m.start()
    try await Task.sleep(for: .milliseconds(200))
    await m.stop()
    let count = await sim.sent.count
    try await Task.sleep(for: .milliseconds(400))
    #expect(await sim.sent.count == count)
    #expect(m.phase == .idle)
}

@Test func errorMappingCoversEveryKey() {
    let cases: [(Error, String)] = [
        (SessionError.notConnected, "error.notConnected"),
        (SessionError.timeout("x"), "error.timeout"),
        (SessionError.readBackMismatch("x"), "error.readBack"),
        (SessionError.rejected(.writeNotAllowed("x")), "error.readOnly"),
        (SessionError.unsupported("read-only model"), "error.readOnly"),
        (SessionError.rejected(.blocked("x")), "error.unsupported"),
        (SessionError.unsupported("equalizer"), "error.unsupported"),
        (SessionError.transport(.bluetoothUnavailable), "error.bluetooth"),
        (SessionError.transport(.deviceNotFound), "error.bluetooth"),
        (SessionError.transport(.deviceNotConnected), "error.bluetooth"),
        (SessionError.transport(.writeFailed(1)), "error.link"),
        (SessionError.linkDead, "error.link"),
        (TransportError.deviceNotFound, "error.bluetooth"),
        (TransportError.openTimedOut, "error.connect"),
        (TransportError.gaiaServiceNotFound, "error.connect"),
        (TransportError.openFailed(5), "error.connect"),
        (SessionError.transport(.openTimedOut), "error.connect"),
        (TransportError.notOpen, "error.link"),
        (TransportError.writeFailed(2), "error.link"),
        (CatalogError.writeNotAllowed("x"), "error.readOnly"),
        (CatalogError.blocked("x"), "error.unsupported"),
        (SessionError.device(command: "x", code: 1), "error.other"),
        (CancellationError(), "error.other"),
    ]
    for (error, key) in cases { #expect(AppModel.userMessage(for: error).key == key, "\(error)") }
}

@MainActor @Test func tappingTheActiveNoiseModeWritesNothing() async {
    let sim = SimulatedHeadset(); let m = model(sim); await m.start()   // starts in ANC
    let before = await sim.sent.count
    await m.setNoiseMode(.anc)
    #expect(m.lastError == nil); #expect(m.state?.noiseMode == .anc)
    #expect(await sim.sent.dropFirst(before).map(\.command).allSatisfy { !writeCommands.contains($0) })
    await m.setNoiseMode(.off)
    let mid = await sim.sent.count
    await m.setNoiseMode(.off)   // already off
    #expect(m.lastError == nil); #expect(m.state?.noiseMode == .off)
    #expect(await sim.sent.dropFirst(mid).map(\.command).allSatisfy { !writeCommands.contains($0) })
    await m.stop()
}

@MainActor @Test func anUnknownEQIsReReadBeforeAPresetIsApplied() async {
    let sim = SimulatedHeadset(); let m = model(sim); await m.start()
    await sim.failSends(after: 8)
    await m.applyPreset("Rock")           // dies half way: eq becomes unknown
    #expect(m.state?.eq == nil)
    await sim.failSends(after: 100_000)   // simulator back to normal
    await m.applyPreset("Pop")
    #expect(m.lastError == nil)
    #expect(m.selectedPreset == "Pop")
    await m.stop()
}

@MainActor @Test func withBothFlagsOnTappingAncIsNotANoOpAndTappingTransparencyIs() async {
    var st = SimulatedState.accentumProbed; st.transparencyEnabled = true      // both flags on: shown as transparency
    let sim = SimulatedHeadset(state: st); let m = model(sim); await m.start()
    #expect(m.state?.noiseMode == .transparency)
    let before = await sim.sent.count
    await m.setNoiseMode(.transparency)                                         // active: no write
    #expect(await sim.sent.dropFirst(before).map(\.command).allSatisfy { !writeCommands.contains($0) })
    let mid = await sim.sent.count
    await m.setNoiseMode(.anc)                                                  // must write 1804 [00]
    let writes = await sim.sent.dropFirst(mid).filter { writeCommands.contains($0.command) }
    #expect(writes.map(\.command) == [0x1804]); #expect(writes.first?.payload == Data([0]))
    #expect(m.state?.noiseMode == .anc); #expect(m.lastError == nil)
    await m.stop()
}

// MARK: Pause music in Transparency

@MainActor @Test func startShowsTheRealPauseValueWithoutAnyPauseWrite() async {
    var st = SimulatedState.accentumProbed; st.pauseInTransparency = false
    let sim = SimulatedHeadset(state: st); let m = model(sim); await m.start()
    #expect(m.phase == .connected); #expect(m.state?.pauseInTransparency == false)
    let cmds = await sim.sent.map(\.command)
    #expect(cmds.contains(0x1801)); #expect(!cmds.contains(0x1800))
    await m.stop()
}

@MainActor @Test func aFailingPauseReadAtStartDoesNotFailTheStart() async {
    let sim = SimulatedHeadset(); await sim.setSilent([0x1801]); let m = model(sim); await m.start()
    #expect(m.phase == .connected); #expect(m.state?.pauseInTransparency == nil); #expect(m.lastError == nil)
    #expect(await sim.sent.map(\.command).contains(0x1800) == false)
    await m.stop()
}

@MainActor @Test func switchingPauseOffRefreshesThenWritesExactlyOneZero() async {
    let sim = SimulatedHeadset(); let m = model(sim); await m.start()
    #expect(m.state?.pauseInTransparency == true)
    let before = await sim.sent.count
    await m.setPauseInTransparency(false)
    let frames = await sim.sent.dropFirst(before)
    let writes = frames.filter { $0.command == 0x1800 }
    #expect(writes.count == 1); #expect(writes.first?.payload == Data([0x00]))
    #expect(frames.map(\.command) == [0x0603, 0x0602, 0x0800, 0x1A05, 0x1805, 0x0804, 0x1801, 0x1800, 0x1801])
    #expect(m.state?.pauseInTransparency == false); #expect(m.lastError == nil)
    #expect(await sim.state.pauseInTransparency == false)
    await m.stop()
}

@MainActor @Test func switchingPauseToTheValueItAlreadyHasWritesNothing() async {
    var st = SimulatedState.accentumProbed; st.pauseInTransparency = false
    let sim = SimulatedHeadset(state: st); let m = model(sim); await m.start()
    let before = await sim.sent.count
    await m.setPauseInTransparency(false)
    #expect(await sim.sent.dropFirst(before).map(\.command).allSatisfy { !writeCommands.contains($0) })
    #expect(m.lastError == nil); #expect(m.state?.pauseInTransparency == false)
    await m.stop()
}

@MainActor @Test func pauseChangedOnTheHeadsetIsNotOverwrittenWhenItAlreadyMatches() async {
    let sim = SimulatedHeadset(); let m = model(sim); await m.start()   // model shows true
    await sim.update { $0.pauseInTransparency = false }                 // changed behind the app's back
    let before = await sim.sent.count
    await m.setPauseInTransparency(false)
    #expect(await sim.sent.dropFirst(before).map(\.command).allSatisfy { !writeCommands.contains($0) })
    #expect(m.state?.pauseInTransparency == false)
    await m.stop()
}

@MainActor @Test func aFailingRefreshBeforeThePauseWriteSendsNoWrite() async {
    let sim = SimulatedHeadset(); let m = model(sim); await m.start()
    await sim.setSilent(deadLink)
    let before = await sim.sent.count
    await m.setPauseInTransparency(false)
    #expect(m.lastError?.key == "error.link")
    let after = await sim.sent.dropFirst(before).map(\.command)
    #expect(!after.isEmpty); #expect(after.allSatisfy { !writeCommands.contains($0) })
    await m.stop()
}

@MainActor @Test func pauseWriteIgnoredByTheDeviceShowsTheDeviceValueAndAnError() async {
    let sim = SimulatedHeadset(); await sim.setIgnoreWrites([0x1800]); let m = model(sim); await m.start()
    await m.setPauseInTransparency(false)
    #expect(m.lastError?.key == "error.readBack"); #expect(m.state?.pauseInTransparency == true)
    await m.stop()
}

@MainActor @Test func pauseOnAReadOnlyModelOrWithoutConnectionWritesNothing() async {
    var m4 = SimulatedState.accentumProbed; m4.modelID = "M4AEBT Denim"
    let sim = SimulatedHeadset(state: m4); let ro = model(sim); await ro.start()
    let before = await sim.sent.count
    await ro.setPauseInTransparency(false)
    #expect(await sim.sent.dropFirst(before).map(\.command).allSatisfy { !writeCommands.contains($0) })
    await ro.stop()
    let idle = model(SimulatedHeadset()); await idle.setPauseInTransparency(false)
    #expect(idle.lastError?.key == "error.notConnected")
}
