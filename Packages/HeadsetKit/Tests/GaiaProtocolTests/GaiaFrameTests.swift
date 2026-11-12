import Testing
import Foundation
@testable import GaiaProtocol

private func hex(_ s: String) -> Data {
    Data(s.split(separator: " ").map { UInt8($0, radix: 16)! })
}

@Test func encodesBatteryGet() throws {
    let f = GaiaFrame(vendor: 0x0495, command: 0x0603, payload: Data())
    #expect(try f.encoded() == hex("FF 03 00 00 04 95 06 03"))
}

@Test func encodesPayload() throws {
    let f = GaiaFrame(vendor: 0x0495, command: 0x100B, payload: Data([0x02]))
    #expect(try f.encoded() == hex("FF 03 00 01 04 95 10 0B 02"))
}

@Test func rejectsOversizedPayload() {
    let f = GaiaFrame(vendor: 0x0495, command: 0x0603, payload: Data(count: 255))
    #expect(throws: GaiaError.payloadTooLarge(255)) { try f.encoded() }
}

@Test func classifiesKinds() {
    #expect(GaiaFrame(vendor: 0x0495, command: 0x0603, payload: Data()).kind == .command)
    #expect(GaiaFrame(vendor: 0x0495, command: 0x0683, payload: Data()).kind == .notification)
    #expect(GaiaFrame(vendor: 0x0495, command: 0x0703, payload: Data()).kind == .response)
    #expect(GaiaFrame(vendor: 0x0495, command: 0x0783, payload: Data()).kind == .error)
    #expect(GaiaFrame(vendor: 0x0495, command: 0x0783, payload: Data()).baseCommand == 0x0603)
}

@Test func decodesWholeFrame() {
    var d = GaiaDeframer()
    let frames = d.append(hex("FF 03 00 01 04 95 07 03 50"))
    #expect(frames == [GaiaFrame(vendor: 0x0495, command: 0x0703, payload: Data([0x50]))])
}

@Test func decodesFrameSplitAcrossReads() {
    var d = GaiaDeframer()
    #expect(d.append(hex("FF 03 00 01 04")).isEmpty)
    #expect(d.append(hex("95 07 03")).isEmpty)
    #expect(d.append(hex("50")) == [GaiaFrame(vendor: 0x0495, command: 0x0703, payload: Data([0x50]))])
}

@Test func decodesTwoFramesInOneRead() {
    var d = GaiaDeframer()
    let frames = d.append(hex("FF 03 00 00 04 95 07 03 FF 03 00 01 04 95 06 83 46"))
    #expect(frames.count == 2)
    #expect(frames[1].payload == Data([0x46]))
}

@Test func skipsGarbageBeforeStart() {
    var d = GaiaDeframer()
    let frames = d.append(hex("00 12 FF 03 00 00 04 95 07 03"))
    #expect(frames == [GaiaFrame(vendor: 0x0495, command: 0x0703, payload: Data())])
}

@Test func skipsUnsupportedVersionAndFlags() {
    var d = GaiaDeframer()
    // version 04, then flag 02: both are skipped, then a valid frame follows
    let frames = d.append(hex("FF 04 00 00 FF 03 02 00 FF 03 00 00 04 95 07 03"))
    #expect(frames == [GaiaFrame(vendor: 0x0495, command: 0x0703, payload: Data())])
}
