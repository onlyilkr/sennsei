import Testing
@testable import HeadsetCore

@Test func recognisesModels() {
    #expect(HeadsetModel(modelID: "ACAEBT SE") == .accentum)
    #expect(HeadsetModel(modelID: "ACPAEBT Black") == .accentumPlus)
    #expect(HeadsetModel(modelID: "M4AEBT Denim") == .momentum4)
    #expect(HeadsetModel(modelID: "XYZ") == .unknown("XYZ"))
}

@Test func accentumOnTheProbedFirmwareUsesGen1() {
    let p = CapabilityProfile(modelID: "ACAEBT SE", firmware: FirmwareVersion(3, 12, 14))
    #expect(p.eq == .gen1); #expect(p.eqParams != nil); #expect(p.sidetoneMax == 2); #expect(p.isWritable)
}

@Test func eqGenerationBoundaries() {
    #expect(CapabilityProfile(modelID: "ACAEBT", firmware: FirmwareVersion(2, 11, 9)).eq == .none)
    #expect(CapabilityProfile(modelID: "ACAEBT", firmware: FirmwareVersion(2, 12, 0)).eq == .gen1)
    #expect(CapabilityProfile(modelID: "ACAEBT", firmware: FirmwareVersion(3, 16, 3)).eq == .gen1)
    #expect(CapabilityProfile(modelID: "ACAEBT", firmware: FirmwareVersion(3, 16, 4)).eq == .gen2)
    #expect(CapabilityProfile(modelID: "M4AEBT", firmware: FirmwareVersion(3, 17, 0)).eq == .gen1)
    #expect(CapabilityProfile(modelID: "M4AEBT", firmware: FirmwareVersion(3, 18, 0)).eq == .gen2)
}

@Test func unverifiedAndUnknownModelsAreReadOnly() {
    #expect(CapabilityProfile(modelID: "ACPAEBT", firmware: FirmwareVersion(3, 12, 0)).isWritable == false)
    #expect(CapabilityProfile(modelID: "M4AEBT", firmware: FirmwareVersion(3, 38, 3)).isWritable == false)
    let u = CapabilityProfile(modelID: "???", firmware: FirmwareVersion(9, 9, 9))
    #expect(u.isWritable == false); #expect(u.eq == .none); #expect(u.eqParams == nil)
}
