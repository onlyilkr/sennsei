import Testing
import Foundation
import GaiaProtocol
@testable import HeadsetCore

private let fw = FirmwareVersion(3, 34, 0)
private func frame(_ id: UInt16, _ payload: [UInt8] = [], vendor: UInt16 = 0x0495) -> GaiaFrame {
    GaiaFrame(vendor: vendor, command: id, payload: Data(payload))
}

@Test func allowsVerifiedGet() throws {
    try CommandCatalog.standard.validate(frame(0x0603), firmware: fw, mode: .readOnly)
}

@Test func rejectsUnknownCommand() {
    #expect(throws: CatalogError.unknownCommand(0x0495, 0x7777)) {
        try CommandCatalog.standard.validate(frame(0x7777), firmware: fw, mode: .readWrite)
    }
}

private let blockedCases: [(UInt16, UInt16)] = [
    (GaiaVendor.sennheiser, 0x0040), (GaiaVendor.sennheiser, 0x1403), (GaiaVendor.sennheiser, 0x1405),
    (GaiaVendor.sennheiser, 0x1406), (GaiaVendor.sennheiser, 0x0200), (GaiaVendor.sennheiser, 0x0201),
    (GaiaVendor.sennheiser, 0x0607), (GaiaVendor.sennheiser, 0x0613), (GaiaVendor.sennheiser, 0x0685),
    (GaiaVendor.sennheiser, 0x1600), (GaiaVendor.sennheiser, 0x1604), (GaiaVendor.sennheiser, 0x0817),
    (GaiaVendor.qualcomm, 0x000D), (GaiaVendor.qualcomm, 0x0009), (GaiaVendor.qualcomm, 0x000A),
    (GaiaVendor.qualcomm, 0x0803), (GaiaVendor.qualcomm, 0x0804), (GaiaVendor.qualcomm, 0x0C00),
    (GaiaVendor.qualcomm, 0x0C01), (GaiaVendor.qualcomm, 0x0C02), (GaiaVendor.qualcomm, 0x0601),
]

@Test(arguments: blockedCases)
func blocksDangerousCommands(vendor: UInt16, id: UInt16) {
    #expect(throws: CatalogError.self) {
        try CommandCatalog.standard.validate(frame(id, [0x00], vendor: vendor), firmware: fw, mode: .readWrite)
    }
    #expect(CommandCatalog.standard.spec(vendor: vendor, id: id)?.status == .blocked)
}

@Test func readOnlyModeRejectsEverySet() {
    #expect(throws: CatalogError.writeNotAllowed("setAncEnabled")) {
        try CommandCatalog.standard.validate(frame(0x1A04, [0x01]), firmware: fw, mode: .readOnly)
    }
}

@Test func rejectsWrongPayloadLength() {
    #expect(throws: CatalogError.badPayload("eqBandFrequency")) {
        try CommandCatalog.standard.validate(frame(0x100B), firmware: fw, mode: .readOnly)
    }
}

@Test func gatesEqOnFirmware() {
    #expect(throws: CatalogError.firmwareTooOld("eqConfig")) {
        try CommandCatalog.standard.validate(frame(0x1000), firmware: FirmwareVersion(3, 16, 3), mode: .readOnly)
    }
    #expect(throws: CatalogError.firmwareTooOld("eqConfig")) {
        try CommandCatalog.standard.validate(frame(0x1000), firmware: nil, mode: .readOnly)
    }
}

@Test func parsesFirmwarePayload() {
    #expect(FirmwareVersion(payload: Data([0x00, 0x03, 0x00, 0x22, 0x00, 0x00])) == FirmwareVersion(3, 34, 0))
    #expect(FirmwareVersion(payload: Data([0x00, 0x03])) == nil)
    #expect(FirmwareVersion(3, 16, 4) > FirmwareVersion(3, 16, 3))
}

private let zeroVersion = FirmwareVersion(0, 0, 0)

private func rangesOverlap(_ a: CommandSpec, _ b: CommandSpec) -> Bool {
    let aLow = a.minFirmware ?? zeroVersion, bLow = b.minFirmware ?? zeroVersion
    // [low, high) half-open; nil high = unbounded.
    let aStartsBeforeBEnds = b.maxFirmwareExclusive.map { aLow < $0 } ?? true
    let bStartsBeforeAEnds = a.maxFirmwareExclusive.map { bLow < $0 } ?? true
    return aStartsBeforeBEnds && bStartsBeforeAEnds
}

@Test func sharedIdsHaveDisjointFirmwareRanges() {
    let specs = CommandCatalog.standard.allSpecs
    let groups = Dictionary(grouping: specs) { "\($0.vendor):\($0.id)" }
    for (key, group) in groups where group.count > 1 {
        #expect(group.allSatisfy { $0.status != .blocked }, "blocked spec shares id \(key)")
        for i in group.indices {
            for j in group.indices where j > i {
                #expect(!rangesOverlap(group[i], group[j]), "overlapping firmware ranges for \(key)")
            }
        }
    }
}

@Test func overlappingRangesAreNotAcceptedAsLegitimate() {
    func spec(_ min: FirmwareVersion?, _ max: FirmwareVersion?) -> CommandSpec {
        CommandSpec(vendor: 0x0495, id: 0x7002, name: "ov", access: .get, payload: .empty,
                    minFirmware: min, maxFirmwareExclusive: max, status: .verified)
    }
    #expect(rangesOverlap(spec(nil, nil), spec(FirmwareVersion(1, 0, 0), nil)))
    #expect(!rangesOverlap(spec(nil, FirmwareVersion(2, 0, 0)), spec(FirmwareVersion(2, 0, 0), nil)))
}

@Test func duplicateNeverUnblocksABlockedEntry() {
    func spec(_ status: CommandStatus) -> CommandSpec {
        CommandSpec(vendor: 0x0495, id: 0x7001, name: "dup", access: .get, payload: .empty, status: status)
    }
    for specs in [[spec(.blocked), spec(.verified)], [spec(.verified), spec(.blocked)]] {
        let catalog = CommandCatalog(specs, reportDuplicates: false)
        #expect(catalog.spec(vendor: 0x0495, id: 0x7001)?.status == .blocked)
        #expect(throws: CatalogError.blocked("dup")) {
            try catalog.validate(frame(0x7001), firmware: fw, mode: .readOnly)
        }
    }
}

private let gen1FW = FirmwareVersion(3, 12, 14)
private let gen2FW = FirmwareVersion(3, 34, 0)

@Test func command1002IsAWriteOnGen1AndAReadOnGen2() throws {
    let c = CommandCatalog.standard
    #expect(throws: CatalogError.writeNotAllowed("eq1SetParams")) {
        try c.validate(frame(0x1002, [UInt8](repeating: 0, count: 72)), firmware: gen1FW, mode: .readOnly)
    }
    try c.validate(frame(0x1002, [0x00]), firmware: gen2FW, mode: .readOnly)
    #expect(throws: CatalogError.badPayload("eqBandGain")) {
        try c.validate(frame(0x1002, [UInt8](repeating: 0, count: 72)), firmware: gen2FW, mode: .readWrite, allowUnverifiedWrites: true)
    }
}

@Test func gen1CommandsNeedAKnownFirmware() {
    #expect(throws: CatalogError.firmwareTooOld("eqBandGain")) {
        try CommandCatalog.standard.validate(frame(0x1002, [0x00]), firmware: nil, mode: .readOnly)
    }
}

@Test func gen1ReadsAreAllowedInRange() throws {
    let c = CommandCatalog.standard
    try c.validate(frame(0x1007), firmware: gen1FW, mode: .readOnly)
    try c.validate(frame(0x1005, [0x00, 0x01]), firmware: gen1FW, mode: .readOnly)
    try c.validate(frame(0x1003, [UInt8](repeating: 0, count: 22)), firmware: gen1FW, mode: .readOnly)
    #expect(throws: CatalogError.firmwareTooOld("eq1LevelShift")) {
        try c.validate(frame(0x1007), firmware: gen2FW, mode: .readOnly)
    }
    #expect(throws: CatalogError.firmwareTooOld("eq1LevelShift")) {
        try c.validate(frame(0x1007), firmware: FirmwareVersion(2, 11, 9), mode: .readOnly)
    }
}

@Test func unverifiedWritesNeedTheExplicitFlag() throws {
    let c = CommandCatalog.standard
    #expect(throws: CatalogError.unverifiedWrite("setAudioMode")) {
        try c.validate(frame(0x0803, [0x00, 0x01]), firmware: gen1FW, mode: .readWrite)
    }
    try c.validate(frame(0x0803, [0x00, 0x01]), firmware: gen1FW, mode: .readWrite, allowUnverifiedWrites: true)
    for id: UInt16 in [0x1002, 0x1006, 0x1004] {   // Gen1 EQ writes are verified on the device
        let payload = [UInt8](repeating: 0, count: id == 0x1002 ? 72 : id == 0x1006 ? 1 : 4)
        try c.validate(frame(id, payload), firmware: gen1FW, mode: .readWrite)
    }
    try c.validate(frame(0x1A04, [0x01]), firmware: gen1FW, mode: .readWrite)   // verified: no flag needed
}

@Test(arguments: blockedCases)
func blockedStaysBlockedInEveryModeAndWithTheFlag(vendor: UInt16, id: UInt16) {
    for mode in [SendMode.readOnly, .readWrite] {
        for allow in [false, true] {
            #expect(throws: CatalogError.self) {
                try CommandCatalog.standard.validate(frame(id, [0x00], vendor: vendor), firmware: gen1FW, mode: mode, allowUnverifiedWrites: allow)
            }
        }
    }
}

@Test func blockedStaysBlockedWithTheFlag() {
    #expect(throws: CatalogError.blocked("factoryReset")) {
        try CommandCatalog.standard.validate(frame(0x0040), firmware: gen1FW, mode: .readWrite, allowUnverifiedWrites: true)
    }
}

@Test func disjointFirmwareRangesMayShareAnId() {
    #expect(CommandCatalog.standard.specs(vendor: 0x0495, id: 0x1002).count == 2)
    #expect(CommandCatalog.standard.specs(vendor: 0x0495, id: 0x0603).count == 1)
}
