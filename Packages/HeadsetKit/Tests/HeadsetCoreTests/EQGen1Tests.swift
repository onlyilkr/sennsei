import Testing
import Foundation
import GaiaProtocol
@testable import HeadsetCore

/// Hardware recordings from our own ACCENTUM Wireless SE (firmware 3.12.14): for each write the probe stored the
/// requested gains and the equalizer read back from the headphones afterwards (`Fixtures/eq1-write-*.json`).
private struct WriteRecording: Decodable {
    struct Readback: Decodable {
        let gains: [Double]?
        let gainResponse: [Int16]
        let filterTypes: [Int16]
        let levelShiftX10: Int8
        let knobY: UInt16
        let bassBoost: Bool?
    }
    let firmware: String
    let requestedGains: [Double]
    let requestedBassBoost: Bool
    let after: Readback
}

/// What is compared, and why only that:
/// - `levelShiftX10` and `knobY` are read back with the same encoding they are written in: compared exactly.
/// - `gainResponse` holds the master gain (word 2) and the four shelf steps (words 4, 6, 8, 10) in units of 1/60 dB.
///   The master is compared exactly. The shelf steps are compared within 1 unit: the headphones answered -239 and
///   -359 where the encoder writes -240 and -360 (they store the value with a rounding of their own), so an exact
///   match is not what the hardware shows and is not claimed.
/// - `filterTypes` (the 11 at each shelf) are compared exactly.
/// - The gains decoded from the read-back must equal the requested ones.
/// The bytes of the three write frames themselves were not captured in these files, so the encoder's output is
/// checked against what the headphones accepted and reported, not against a byte capture.
@Test func encodingMatchesWhatTheHeadphonesReadBack() throws {
    let folder = try #require(Bundle.module.resourceURL).appendingPathComponent("Fixtures")
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        .filter { $0.hasPrefix("eq1-write-") && $0.hasSuffix(".json") }.sorted()
    #expect(names.count == 3)
    for name in names {
        let rec = try JSONDecoder().decode(WriteRecording.self, from: Data(contentsOf: folder.appendingPathComponent(name)))
        #expect(rec.firmware == "3.12.14")
        let e = try EQGen1.encode(.accentum, gains: rec.requestedGains, bassBoost: rec.requestedBassBoost)
        let r = rec.after
        #expect(e.levelShiftX10 == r.levelShiftX10, "level shift in \(name)")
        #expect(e.knobY == r.knobY, "knob in \(name)")
        #expect(r.gainResponse.count == 11)
        #expect(Int(e.params[2]) == Int(r.gainResponse[2]), "master in \(name)")
        for (i, word) in [(8, 4), (16, 6), (24, 8), (32, 10)] {
            #expect(abs(Int(e.params[i]) - Int(r.gainResponse[word])) <= 1, "shelf word \(word) in \(name)")
        }
        let shelfTypes = [r.filterTypes[2], r.filterTypes[4], r.filterTypes[6], r.filterTypes[8]]
        #expect(shelfTypes == [e.params[4], e.params[12], e.params[20], e.params[28]], "filter types in \(name)")
        let decoded = try #require(EQGen1.decode(.accentum, levelShiftX10: r.levelShiftX10, bassBoost: r.bassBoost ?? false,
                                                 gainResponse: r.gainResponse))
        #expect(decoded == rec.requestedGains, "decoded gains in \(name)")
    }
}

@Test func accentumFlatEncoding() throws {
    let e = try EQGen1.encode(.accentum, gains: [0, 0, 0, 0, 0], bassBoost: false)
    #expect(e.params == [17, 257, 0,
                         272, 11, 273, 375, 274, 0, 275, 2896,
                         288, 11, 289, 1200, 290, 0, 291, 2896,
                         304, 11, 305, 4800, 306, 0, 307, 2896,
                         320, 11, 321, 15000, 322, 0, 323, 2896,
                         0])
    #expect(e.levelShiftX10 == 0)
    #expect(e.knobY == 0x4000)
}

@Test func accentumBoostLowersOverallLevel() throws {
    // headroom 0: a +6 dB band pulls the level down by about 6 dB
    let e = try EQGen1.encode(.accentum, gains: [6, 0, 0, 0, 0], bassBoost: false)
    #expect(e.levelShiftX10 == -60)
    #expect(e.params[2] == 0)        // master = 6 + (−6) = 0
    #expect(e.params[8] == -360)     // shelf0 = −6 dB × 60
}

@Test func gainsAreClampedAndCounted() throws {
    let clamped = try EQGen1.encode(.accentum, gains: [9, 0, 0, 0, -9], bassBoost: false)
    let limit = try EQGen1.encode(.accentum, gains: [6, 0, 0, 0, -6], bassBoost: false)
    #expect(clamped == limit)
    #expect(throws: EQGen1Error.wrongBandCount(4)) { try EQGen1.encode(.accentum, gains: [0, 0, 0, 0], bassBoost: false) }
}

@Test func writeFramesAreThreeInOrder() throws {
    let frames = EQGen1.writeFrames(try EQGen1.encode(.accentum, gains: [0, 0, 0, 0, 0], bassBoost: true))
    #expect(frames.map(\.command) == [0x1002, 0x1006, 0x1004])
    #expect(frames[0].payload.count == 72)
    #expect(Array(frames[0].payload.prefix(6)) == [0x00, 0x11, 0x01, 0x01, 0x00, 0x00])   // 17, 0x0101, master 0
    #expect(Array(frames[1].payload) == [0xCE])                                           // slider −5.0 dB → −50
    #expect(Array(frames[2].payload) == [0x00, 0x01, 0x50, 0x00])
    #expect(frames.allSatisfy { $0.vendor == GaiaVendor.sennheiser })
}

@Test func readFramesAreFourInOrder() {
    let frames = EQGen1.readFrames()
    #expect(frames.map(\.command) == [0x1007, 0x1005, 0x1003, 0x1003])
    #expect(Array(frames[1].payload) == [0x00, 0x01])
    #expect(EQGen1.words(frames[2].payload) == EQGen1.gainQuery)
    #expect(EQGen1.words(frames[3].payload) == EQGen1.filterTypeQuery)
}

@Test func decodeRoundTripsEveryAccentumPreset() throws {
    for preset in EQPresets.accentum {
        for bass in [false, true] {
            let e = try EQGen1.encode(.accentum, gains: preset.gains, bassBoost: bass)
            let rsp: [Int16] = [5, 257, e.params[2], 274, e.params[8], 290, e.params[16], 306, e.params[24], 322, e.params[32]]
            let back = try #require(EQGen1.decode(.accentum, levelShiftX10: e.levelShiftX10, bassBoost: bass, gainResponse: rsp))
            for k in 0..<5 { #expect(abs(back[k] - preset.gains[k]) < 0.11, "\(preset.name) bass=\(bass) band \(k)") }
        }
    }
}

@Test func knobAndFilterHelpers() {
    #expect(EQGen1.bassBoost(fromKnobY: 0x4000) == false)
    #expect(EQGen1.bassBoost(fromKnobY: 0x5000) == true)
    #expect(EQGen1.bassBoost(fromKnobY: 0xFF00) == nil)
    #expect(EQGen1.bassBoost(fromKnobY: 0x0000) == nil)
    #expect(EQGen1.isUnconfigured(filterTypes: [4, 272, 0, 288, 0, 304, 0, 320, 0]))
    #expect(EQGen1.isUnconfigured(filterTypes: [4, 272, 11, 288, 11, 304, 11, 320, 11]) == false)
    #expect(EQGen1.decode(.accentum, levelShiftX10: 0, bassBoost: false, gainResponse: [5, 257, 0]) == nil)
    #expect(EQGen1.words(EQGen1.payload([-78, 2896, 15000])) == [-78, 2896, 15000])
}

@Test func nonFiniteGainsAreRejected() {
    for bad in [Double.nan, .infinity, -.infinity] {
        for band in 0..<5 {
            var g = [0.0, 0, 0, 0, 0]; g[band] = bad
            #expect(throws: EQGen1Error.nonFiniteGain) { try EQGen1.encode(.accentum, gains: g, bassBoost: false) }
        }
    }
    #expect(throws: EQGen1Error.wrongBandCount(4)) { try EQGen1.encode(.accentum, gains: [.nan, 0, 0, 0], bassBoost: false) }
}
