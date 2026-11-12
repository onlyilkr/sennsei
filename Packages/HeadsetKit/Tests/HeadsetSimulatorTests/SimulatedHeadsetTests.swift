import Testing
import Foundation
import GaiaProtocol
import HeadsetCore
@testable import HeadsetSimulator

private func hexData(_ s: String) -> Data {
    var d = Data(); var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return d
}
private struct Row: Decodable { let tx: String; let rx: [String]; let note: String }

private func firstReply(_ sim: SimulatedHeadset, to frame: GaiaFrame) async throws -> GaiaFrame {
    var it = sim.incoming.makeAsyncIterator()
    try await sim.send(frame.encoded())
    var d = GaiaDeframer()
    while let chunk = await it.next() { if let f = d.append(chunk).first { return f } }
    throw TransportError.notOpen
}

@Test func replaysTheProbeCapture() async throws {
    let url = try #require(Bundle.module.url(forResource: "accentum-3.12.14-20261111-013741", withExtension: "jsonl", subdirectory: "Fixtures"))
    let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
    #expect(rows.count == 26)
    for row in rows where !row.note.hasPrefix("paired") && row.note != "ownPairedIndex" && row.note != "maxLinks" {
        let sim = SimulatedHeadset()
        var d = GaiaDeframer()
        let request = try #require(d.append(hexData(row.tx)).first)
        let reply = try await firstReply(sim, to: request)
        #expect(try reply.encoded() == hexData(row.rx[0]), "\(row.note)")
    }
}

@Test func gen1WriteThenReadBack() async throws {
    let sim = SimulatedHeadset()
    let e = try EQGen1.encode(.accentum, gains: [2, -3, -3, 1, 1], bassBoost: true)
    for f in EQGen1.writeFrames(e) { #expect(try await firstReply(sim, to: f).kind == .response) }
    let reads = EQGen1.readFrames()
    #expect(Array(try await firstReply(sim, to: reads[0]).payload) == [UInt8(bitPattern: e.levelShiftX10)])
    #expect(Array(try await firstReply(sim, to: reads[1]).payload) == [0x50, 0x00])
    let gains = EQGen1.words(try await firstReply(sim, to: reads[2]).payload)
    #expect(gains == [5, 257, e.params[2], 274, e.params[8], 290, e.params[16], 306, e.params[24], 322, e.params[32]])
    let types = EQGen1.words(try await firstReply(sim, to: reads[3]).payload)
    #expect(types == [4, 272, 11, 288, 11, 304, 11, 320, 11])
}

@Test func gen1CommandsAreErrorsOnGen2Firmware() async throws {
    var s = SimulatedState.accentumProbed; s.firmware = FirmwareVersion(3, 34, 0)
    let reply = try await firstReply(SimulatedHeadset(state: s), to: GaiaFrame(vendor: 0x0495, command: 0x1007, payload: Data()))
    #expect(reply.kind == .error); #expect(reply.baseCommand == 0x1007)
}

@Test func unknownCommandIsAnError() async throws {
    let reply = try await firstReply(SimulatedHeadset(), to: GaiaFrame(vendor: 0x0495, command: 0x7777, payload: Data()))
    #expect(reply.kind == .error); #expect(Array(reply.payload) == [0x01])
}

@Test func ignoredWritesAnswerButChangeNothing() async throws {
    let sim = SimulatedHeadset()
    await sim.setIgnoreWrites([0x1A04])
    #expect(try await firstReply(sim, to: GaiaFrame(vendor: 0x0495, command: 0x1A04, payload: Data([0x00]))).kind == .response)
    #expect(await sim.state.ancEnabled == true)
}

@Test func failSendsThrows() async throws {
    let sim = SimulatedHeadset()
    await sim.failSends(after: 0)
    await #expect(throws: TransportError.notOpen) { try await sim.send(Data([0xFF])) }
}

@Test func setAudioModeWritesAudioModeOnly() async throws {
    var s = SimulatedState.accentumProbed; s.audioMode = 3
    let sim = SimulatedHeadset(state: s)
    #expect(try await firstReply(sim, to: GaiaFrame(vendor: 0x0495, command: 0x0803, payload: Data([0x00, 0x01]))).kind == .response)
    #expect(await sim.state.audioMode == 1)
    #expect(await sim.state.voicePrompts == 2)
    #expect(Array(try await firstReply(sim, to: GaiaFrame(vendor: 0x0495, command: 0x0804, payload: Data())).payload) == [0x00, 0x01])
}

@Test func setAudioModeWithWrongLengthIsAnError() async throws {
    var s = SimulatedState.accentumProbed; s.audioMode = 3
    let sim = SimulatedHeadset(state: s)
    let reply = try await firstReply(sim, to: GaiaFrame(vendor: 0x0495, command: 0x0803, payload: Data([0x01])))
    #expect(reply.kind == .error); #expect(Array(reply.payload) == [0x01])
    #expect(await sim.state.audioMode == 3)
}

@Test func ancAndTransparencySwitchesAreIndependent() async throws {
    let sim = SimulatedHeadset()   // ANC on, transparency off
    _ = try await firstReply(sim, to: GaiaFrame(vendor: 0x0495, command: 0x1804, payload: Data([0x01])))
    #expect(await sim.state.transparencyEnabled == true); #expect(await sim.state.ancEnabled == true)
    _ = try await firstReply(sim, to: GaiaFrame(vendor: 0x0495, command: 0x1A04, payload: Data([0x00])))
    #expect(await sim.state.transparencyEnabled == true); #expect(await sim.state.ancEnabled == false)
}
