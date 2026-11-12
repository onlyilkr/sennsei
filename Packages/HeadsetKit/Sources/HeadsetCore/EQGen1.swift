import Foundation
import GaiaProtocol

/// Per-model constants for the Gen1 equalizer (firmware 2.12.0 to 3.16.4).
public struct EQGen1Params: Sendable {
    public let minGain, maxGain: Double
    public let bassBoost, loudnessWeights, maxHeadroom: [Double]
    public let qFactor, shelfFrequency: [Double]

    public static let momentum4 = EQGen1Params(
        minGain: -6, maxGain: 6,
        bassBoost: [5, 5, 0, 0, 0],
        loudnessWeights: [-26.683, -10.813, -4.773, -4.813, -5.993],
        maxHeadroom: [5, 5, 4, 3, 2],
        qFactor: Array(repeating: 1 / 2.0.squareRoot(), count: 4),
        shelfFrequency: [120, 400, 3000, 6000])

    public static let accentum = EQGen1Params(
        minGain: -6, maxGain: 6,
        bassBoost: [5, -2, 0, 0, 0],
        loudnessWeights: [-26.683, -10.813, -4.773, -4.813, -5.993],
        maxHeadroom: [0, 0, 0, 0, 0],
        qFactor: Array(repeating: 1 / 2.0.squareRoot(), count: 4),
        shelfFrequency: [125, 400, 1600, 5000])
}

public struct EQGen1Encoded: Equatable, Sendable {
    public let params: [Int16]
    public let levelShiftX10: Int8
    public let knobY: UInt16
}

public enum EQGen1Error: Error, Equatable {
    case wrongBandCount(Int)
    case nonFiniteGain
}

public enum EQGen1 {
    public static let gainQuery: [Int16] = [5, 257, 0, 274, 0, 290, 0, 306, 0, 322, 0]
    public static let filterTypeQuery: [Int16] = [4, 272, 0, 288, 0, 304, 0, 320, 0]

    // MARK: Number rules (JavaScript semantics)

    /// JavaScript Math.round: nearest, ties toward +infinity.
    static func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

    static func wrapped(_ x: Double, modulus: Double) -> Int64 {
        guard x.isFinite else { return 0 }
        return Int64(x.rounded(.towardZero).truncatingRemainder(dividingBy: modulus))
    }
    static func toInt16(_ x: Double) -> Int16 { Int16(truncatingIfNeeded: wrapped(x, modulus: 65536)) }
    static func toInt8(_ x: Double) -> Int8 { Int8(truncatingIfNeeded: wrapped(x, modulus: 256)) }

    // MARK: Encode

    public static func encode(_ p: EQGen1Params, gains: [Double], bassBoost: Bool) throws(EQGen1Error) -> EQGen1Encoded {
        guard gains.count == 5 else { throw .wrongBandCount(gains.count) }
        guard gains.allSatisfy(\.isFinite) else { throw .nonFiniteGain }
        var g = gains.map { min(max($0, p.minGain), p.maxGain) }
        if bassBoost { for i in 0..<5 { g[i] += p.bassBoost[i] } }

        var sum = 0.0
        for i in 0..<5 { sum += pow(10, (g[i] + p.loudnessWeights[i]) / 10) }
        let s = -10 * log10(sum)
        var r = 0.0
        for i in 0..<5 { r = max(r, g[i] + s - p.maxHeadroom[i]) }
        let clipped = r > 0 ? s - r : s
        let levelShift = jsRound(10 * clipped) / 10

        let x = g.map { $0 + levelShift }
        var master = x[0]
        if Int((master * 100).rounded(.towardZero)) == 425 { master = 4.24 }
        var words: [Int16] = [17, 0x0101, toInt16(60 * master)]
        for b in 0..<4 {
            let base = 272 + 16 * b
            words += [
                Int16(base), 11,
                Int16(base + 1), toInt16(3 * p.shelfFrequency[b]),
                Int16(base + 2), toInt16(60 * (x[b + 1] - x[b])),
                Int16(base + 3), toInt16(4096 * p.qFactor[b]),
            ]
        }
        words.append(0)
        return EQGen1Encoded(
            params: words,
            levelShiftX10: toInt8(10 * levelShift),
            knobY: 0x4000 | (bassBoost ? 0x1000 : 0))
    }

    // MARK: Decode

    public static func decode(_ p: EQGen1Params, levelShiftX10: Int8, bassBoost: Bool, gainResponse: [Int16]) -> [Double]? {
        guard gainResponse.count >= 11 else { return nil }
        let o = (0..<5).map { Double(gainResponse[2 + 2 * $0]) / 60 }
        var a = o
        for k in 1..<5 { a[k] = o[k] + a[k - 1] }
        if bassBoost { for i in 0..<5 { a[i] -= p.bassBoost[i] } }
        let shift = Double(levelShiftX10) / 10
        return a.map { jsRound(10 * ($0 - shift)) / 10 }
    }

    public static func bassBoost(fromKnobY y: UInt16) -> Bool? {
        if (y & 0xFF00) == 0xFF00 || (y & 0x4000) == 0 { return nil }
        return (y & 0x1000) != 0
    }

    public static func isUnconfigured(filterTypes: [Int16]) -> Bool {
        filterTypes.count == 9 && filterTypes[6] == 0 && filterTypes[8] == 0
    }

    // MARK: Frames

    public static func writeFrames(_ e: EQGen1Encoded) -> [GaiaFrame] {
        [
            GaiaFrame(vendor: GaiaVendor.sennheiser, command: 0x1002, payload: payload(e.params)),
            GaiaFrame(vendor: GaiaVendor.sennheiser, command: 0x1006, payload: Data([UInt8(bitPattern: e.levelShiftX10)])),
            GaiaFrame(vendor: GaiaVendor.sennheiser, command: 0x1004,
                      payload: Data([0x00, 0x01, UInt8(e.knobY >> 8), UInt8(e.knobY & 0xFF)])),
        ]
    }

    public static func readFrames() -> [GaiaFrame] {
        [
            GaiaFrame(vendor: GaiaVendor.sennheiser, command: 0x1007, payload: Data()),
            GaiaFrame(vendor: GaiaVendor.sennheiser, command: 0x1005, payload: Data([0x00, 0x01])),
            GaiaFrame(vendor: GaiaVendor.sennheiser, command: 0x1003, payload: payload(gainQuery)),
            GaiaFrame(vendor: GaiaVendor.sennheiser, command: 0x1003, payload: payload(filterTypeQuery)),
        ]
    }

    public static func payload(_ words: [Int16]) -> Data {
        var d = Data()
        for w in words { let u = UInt16(bitPattern: w); d.append(UInt8(u >> 8)); d.append(UInt8(u & 0xFF)) }
        return d
    }

    public static func words(_ payload: Data) -> [Int16] {
        let b = Array(payload)
        return stride(from: 0, to: b.count - 1, by: 2).map { Int16(bitPattern: UInt16(b[$0]) << 8 | UInt16(b[$0 + 1])) }
    }
}
