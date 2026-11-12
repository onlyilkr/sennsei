import Testing
import Foundation
import GaiaProtocol
import HeadsetCore
import HeadsetSimulator

@Test func noiseModeFollowsTheTwoSwitches() {
    var s = HeadsetState(profile: CapabilityProfile(modelID: "ACAEBT SE", firmware: FirmwareVersion(3, 12, 14)))
    s.ancEnabled = true; s.transparencyEnabled = false;  #expect(s.noiseMode == .anc)
    s.ancEnabled = false; s.transparencyEnabled = true;  #expect(s.noiseMode == .transparency)
    s.ancEnabled = false; s.transparencyEnabled = false; #expect(s.noiseMode == .off)
    s.ancEnabled = true;  s.transparencyEnabled = true;  #expect(s.noiseMode == .transparency)   // both on: transparency wins
    s.transparencyEnabled = nil;                         #expect(s.noiseMode == nil)
    s.ancEnabled = nil; s.transparencyEnabled = true;    #expect(s.noiseMode == nil)
}

@Test func switchingToTransparencySendsExactlyOneWrite() async throws {
    let sim = SimulatedHeadset(); let sess = HeadsetSession(transport: sim, replyTimeout: .milliseconds(80))
    _ = try await sess.connect()
    try await sess.setNoiseMode(.transparency)
    let writes = await sim.sent.map(\.command).filter { $0 == 0x1A04 || $0 == 0x1804 }
    #expect(writes == [0x1804])
    #expect(await sim.state.transparencyEnabled == true); #expect(await sim.state.ancEnabled == true)   // device keeps ANC on
    #expect(await sess.state?.noiseMode == .transparency)   // read-back passes with both flags on
}

private func noiseWrites(_ sim: SimulatedHeadset, after n: Int = 0) async -> [[UInt8]] {
    await sim.sent.dropFirst(n).filter { $0.command == 0x1A04 || $0.command == 0x1804 }
        .map { [UInt8($0.command >> 8), UInt8($0.command & 0xFF)] + Array($0.payload) }
}

@Test func transparencyAlreadyOnSendsNothing() async throws {
    var st = SimulatedState.accentumProbed; st.transparencyEnabled = true
    let sim = SimulatedHeadset(state: st); let sess = HeadsetSession(transport: sim, replyTimeout: .milliseconds(80))
    _ = try await sess.connect()
    try await sess.setNoiseMode(.transparency)
    #expect(await noiseWrites(sim).isEmpty)
}

@Test func ancFromTransparencySendsExactlyOneTransparencyOff() async throws {
    var st = SimulatedState.accentumProbed; st.transparencyEnabled = true     // both flags on
    let sim = SimulatedHeadset(state: st); let sess = HeadsetSession(transport: sim, replyTimeout: .milliseconds(80))
    _ = try await sess.connect()
    try await sess.setNoiseMode(.anc)
    #expect(await noiseWrites(sim) == [[0x18, 0x04, 0x00]])
    #expect(await sess.state?.noiseMode == .anc)
}

@Test func ancFromAncOffSendsOnlyAncOn() async throws {
    var st = SimulatedState.accentumProbed; st.ancEnabled = false
    let sim = SimulatedHeadset(state: st); let sess = HeadsetSession(transport: sim, replyTimeout: .milliseconds(80))
    _ = try await sess.connect()
    try await sess.setNoiseMode(.anc)
    #expect(await noiseWrites(sim) == [[0x1A, 0x04, 0x01]])
}

@Test func ancWhileAncReadsOffAfterTransparencyOffIsReportedAsMismatch() async throws {
    var st = SimulatedState.accentumProbed; st.ancEnabled = false; st.transparencyEnabled = true
    let sim = SimulatedHeadset(state: st); let sess = HeadsetSession(transport: sim, replyTimeout: .milliseconds(80))
    _ = try await sess.connect()
    await #expect(throws: SessionError.readBackMismatch("noise control")) { try await sess.setNoiseMode(.anc) }
    #expect(await noiseWrites(sim) == [[0x18, 0x04, 0x00]])          // no second write
    #expect(await sess.state?.noiseMode == .off)
}

@Test func offFromBothOnWritesTransparencyThenAncAndNothingElseBetween() async throws {
    var st = SimulatedState.accentumProbed; st.transparencyEnabled = true
    let sim = SimulatedHeadset(state: st); let sess = HeadsetSession(transport: sim, replyTimeout: .milliseconds(80))
    _ = try await sess.connect()
    let before = await sim.sent.count
    try await sess.setNoiseMode(.off)
    let frames = await sim.sent.dropFirst(before).map(\.command)
    #expect(frames == [0x1804, 0x1A04, 0x1A05, 0x1805])
    #expect(await sess.state?.noiseMode == .off)
}

@Test func offFromAncOnlySendsOnlyAncOff() async throws {
    let sim = SimulatedHeadset(); let sess = HeadsetSession(transport: sim, replyTimeout: .milliseconds(80))
    _ = try await sess.connect()
    try await sess.setNoiseMode(.off)
    #expect(await noiseWrites(sim) == [[0x1A, 0x04, 0x00]])
}

@Test func offTurnsOffOnlyTheActiveMode() async throws {
    let sim = SimulatedHeadset(); let sess = HeadsetSession(transport: sim, replyTimeout: .milliseconds(80))
    _ = try await sess.connect()                         // ANC starts enabled
    try await sess.setNoiseMode(.off)
    #expect(await sim.sent.map(\.command).filter { $0 == 0x1A04 || $0 == 0x1804 } == [0x1A04])
    #expect(await sess.state?.noiseMode == .off)
    let before = await sim.sent.count
    try await sess.setNoiseMode(.off)                    // already off: no write
    #expect(await sim.sent.dropFirst(before).map(\.command).contains(0x1A04) == false)
}

@Test func ignoredNoiseWriteIsAReadBackMismatch() async throws {
    let sim = SimulatedHeadset(); await sim.setIgnoreWrites([0x1804])
    let sess = HeadsetSession(transport: sim, replyTimeout: .milliseconds(80)); _ = try await sess.connect()
    await #expect(throws: SessionError.readBackMismatch("noise control")) { try await sess.setNoiseMode(.transparency) }
    #expect(await sess.state?.noiseMode == .anc)         // state tracks the device value
}

@Test func noiseControlOnAReadOnlyModelIsRefused() async throws {
    var st = SimulatedState.accentumProbed; st.modelID = "M4AEBT Denim"
    let sim = SimulatedHeadset(state: st); let sess = HeadsetSession(transport: sim, replyTimeout: .milliseconds(80))
    _ = try await sess.connect(); let sent = await sim.sent.count
    await #expect(throws: SessionError.unsupported("read-only model")) { try await sess.setNoiseMode(.off) }
    #expect(await sim.sent.count == sent)
}

@Test func refreshStatusReadsOnlyAndUpdatesState() async throws {
    let sim = SimulatedHeadset(); let sess = HeadsetSession(transport: sim, replyTimeout: .milliseconds(80))
    _ = try await sess.connect()
    await sim.update { $0.battery = 55; $0.charging = [0, 1] }          // hook for changing state on the simulator
    let s = try await sess.refreshStatus()
    #expect(s.battery == 55); #expect(s.charging == true); #expect(s.codec == 1)
    let refreshFrames = await sim.sent.dropFirst(6).map(\.command)
    #expect(refreshFrames == [0x0603, 0x0602, 0x0800, 0x1A05, 0x1805, 0x0804, 0x1801])
}

@Test func refreshWithoutConnectionFails() async {
    let sess = HeadsetSession(transport: SimulatedHeadset(), replyTimeout: .milliseconds(80))
    await #expect(throws: SessionError.notConnected) { _ = try await sess.refreshStatus() }
}
