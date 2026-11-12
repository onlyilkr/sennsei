import Testing
import HeadsetCore
@testable import HeadsetBluetooth

@Test func picksChannelOfGaiaRecord() throws {
    let records = [
        SDPRecordSummary(serviceUUIDs: ["0000111e-0000-1000-8000-00805f9b34fb"], rfcommChannel: 1),
        SDPRecordSummary(serviceUUIDs: ["00000000-deca-fade-deca-deafdecacaff"], rfcommChannel: 14),
        SDPRecordSummary(serviceUUIDs: ["A2129FF3-081B-4C45-8AFE-469D9C4842EC"], rfcommChannel: 15),
    ]
    #expect(try GaiaServiceLocator.channel(in: records) == 15)
}

@Test func neverFallsBackToAnotherRecord() {
    let records = [
        SDPRecordSummary(serviceUUIDs: ["00000000-deca-fade-deca-deafdecacaff"], rfcommChannel: 14),
        SDPRecordSummary(serviceUUIDs: ["0000111e-0000-1000-8000-00805f9b34fb"], rfcommChannel: 1),
    ]
    #expect(throws: TransportError.gaiaServiceNotFound) { try GaiaServiceLocator.channel(in: records) }
}

@Test func ignoresGaiaRecordWithoutChannel() {
    let records = [SDPRecordSummary(serviceUUIDs: [GaiaServiceLocator.gaiaUUID], rfcommChannel: nil)]
    #expect(throws: TransportError.gaiaServiceNotFound) { try GaiaServiceLocator.channel(in: records) }
}

@Test func emptyRecordListFails() {
    #expect(throws: TransportError.gaiaServiceNotFound) { try GaiaServiceLocator.channel(in: []) }
}

@Test func refusesRecordThatAlsoListsIAP2AndMovesOn() throws {
    let both = SDPRecordSummary(
        serviceUUIDs: [GaiaServiceLocator.gaiaUUID, "00000000-DECA-FADE-DECA-DEAFDECACAFF"], rfcommChannel: 9)
    #expect(throws: TransportError.gaiaServiceNotFound) { try GaiaServiceLocator.channel(in: [both]) }
    let good = SDPRecordSummary(serviceUUIDs: [GaiaServiceLocator.gaiaUUID], rfcommChannel: 15)
    #expect(try GaiaServiceLocator.channel(in: [both, good]) == 15)
}
