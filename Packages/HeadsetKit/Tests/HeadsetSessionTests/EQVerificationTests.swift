import Testing
import Foundation
import HeadsetCore
import HeadsetSimulator

private func connected(_ sim: SimulatedHeadset) async throws -> HeadsetSession {
    let s = HeadsetSession(transport: sim, replyTimeout: .milliseconds(80), allowUnverifiedWrites: true)
    _ = try await s.connect(); return s
}

@Test func parsesExactlyFiveGains() throws {
    #expect(try EQVerification.parseGains("0, 1.5,-2,0,6") == [0, 1.5, -2, 0, 6])
    #expect(throws: EQVerificationError.badGains("0,0,0,0")) { try EQVerification.parseGains("0,0,0,0") }
    #expect(throws: EQVerificationError.badGains("a,0,0,0,0")) { try EQVerification.parseGains("a,0,0,0,0") }
}

@Test func writingWithoutASnapshotSendsNothing() async throws {
    let sim = SimulatedHeadset(); let s = try await connected(sim)
    await #expect(throws: EQVerificationError.missingSnapshot) { _ = try await EQVerification.write(s, gains: [0, 0, 0, 0, 0], bassBoost: false, snapshot: nil) }
    await #expect(throws: EQVerificationError.missingSnapshot) { _ = try await EQVerification.restore(s, snapshot: nil) }
    #expect(await sim.sent.count == 6)
}

@Test func writeThenRestoreReturnsToTheSnapshot() async throws {
    let sim = SimulatedHeadset(); let s = try await connected(sim)
    let snap = try await EQVerification.read(s)
    let r = try await EQVerification.write(s, gains: [2, 0, 0, 0, 0], bassBoost: false, snapshot: snap)
    #expect(r.before == snap); #expect(r.after != snap)
    let back = try await EQVerification.restore(s, snapshot: snap)
    #expect(back.gains == snap.gains); #expect(back.bassBoost == snap.bassBoost)
}

@Test func aSnapshotFromAnotherFirmwareIsRefused() async throws {
    let sim = SimulatedHeadset(); let s = try await connected(sim)
    let snap = try await EQVerification.read(s)
    let other = EQSnapshot(firmware: "3.10.0", levelShiftX10: snap.levelShiftX10, knobY: snap.knobY, gainResponse: snap.gainResponse, filterTypes: snap.filterTypes, gains: snap.gains, bassBoost: snap.bassBoost, isUnconfigured: snap.isUnconfigured)
    await #expect(throws: EQVerificationError.snapshotFirmwareMismatch("3.10.0", "3.12.14")) { _ = try await EQVerification.write(s, gains: [0, 0, 0, 0, 0], bassBoost: false, snapshot: other) }
}

@Test func nonFiniteGainsAreRejected() {
    #expect(throws: EQVerificationError.badGains("nan,0,0,0,0")) { try EQVerification.parseGains("nan,0,0,0,0") }
    #expect(throws: EQVerificationError.badGains("inf,0,0,0,0")) { try EQVerification.parseGains("inf,0,0,0,0") }
}

private func variant(_ snap: EQSnapshot, gains: [Double]?, bass: Bool?, unconfigured: Bool) -> EQSnapshot {
    EQSnapshot(firmware: snap.firmware, levelShiftX10: snap.levelShiftX10, knobY: snap.knobY, gainResponse: snap.gainResponse, filterTypes: snap.filterTypes, gains: gains, bassBoost: bass, isUnconfigured: unconfigured)
}

@Test func restoringAnUnconfiguredOrGainlessSnapshotWritesFlat() async throws {
    let sim = SimulatedHeadset(); let s = try await connected(sim)
    let snap = try await EQVerification.read(s)
    _ = try await EQVerification.write(s, gains: [3, 0, 0, 0, 0], bassBoost: true, snapshot: snap)
    let unconfigured = variant(snap, gains: [5, 5, 5, 5, 5], bass: true, unconfigured: true)
    let a = try await EQVerification.restore(s, snapshot: unconfigured)
    #expect(a.gains == [0, 0, 0, 0, 0]); #expect(a.bassBoost == false)

    _ = try await EQVerification.write(s, gains: [3, 0, 0, 0, 0], bassBoost: true, snapshot: snap)
    let gainless = variant(snap, gains: nil, bass: nil, unconfigured: false)
    let b = try await EQVerification.restore(s, snapshot: gainless)
    #expect(b.gains == [0, 0, 0, 0, 0]); #expect(b.bassBoost == false)
}

@Test func bassBoostRoundTrips() async throws {
    let sim = SimulatedHeadset(); let s = try await connected(sim)
    let snap = try await EQVerification.read(s)
    let r = try await EQVerification.write(s, gains: [0, 0, 0, 0, 0], bassBoost: true, snapshot: snap)
    #expect(r.after.bassBoost == true)
    let back = try await EQVerification.restore(s, snapshot: snap)
    #expect(back.bassBoost == snap.bassBoost); #expect(back.gains == snap.gains)
}

@Test func outOfRangeGainsAreRejectedAndSixIsAccepted() async throws {
    #expect(throws: EQVerificationError.badGains("8,0,0,0,0")) { try EQVerification.parseGains("8,0,0,0,0") }
    #expect(throws: EQVerificationError.badGains("-6.1,0,0,0,0")) { try EQVerification.parseGains("-6.1,0,0,0,0") }
    #expect(try EQVerification.parseGains("6,-6,0,0,0") == [6, -6, 0, 0, 0])

    let sim = SimulatedHeadset(); let s = try await connected(sim)
    let before = await sim.sent.count
    let stateBefore = await s.state
    await #expect(throws: SessionError.unsupported("equalizer gains")) { _ = try await s.writeEQ(gains: [7, 0, 0, 0, 0], bassBoost: false) }
    #expect(await sim.sent.count == before)
    #expect(await s.state == stateBefore)
    _ = try await s.writeEQ(gains: [6, 0, 0, 0, 0], bassBoost: false)
    _ = try await s.writeEQ(gains: [-6, 0, 0, 0, 0], bassBoost: false)
}

@Test func ignoredLevelShiftOrKnobWriteIsAReadBackMismatch() async throws {
    for cmd: UInt16 in [0x1006, 0x1004] {
        let sim = SimulatedHeadset(); let s = try await connected(sim)
        await sim.setIgnoreWrites([cmd])
        await #expect(throws: SessionError.readBackMismatch("equalizer")) { _ = try await s.writeEQ(gains: [2, 0, 0, 0, 0], bassBoost: true) }
    }
}

@Test func unknownAudioModeRefusesTheWrite() async throws {
    let sim = SimulatedHeadset()
    await sim.setSilent([0x0804])
    let s = try await connected(sim)
    let before = await sim.sent.count
    await #expect(throws: SessionError.unsupported("audio mode unknown")) { _ = try await s.writeEQ(gains: [0, 0, 0, 0, 0], bassBoost: false) }
    #expect(await sim.sent.count == before)
}
