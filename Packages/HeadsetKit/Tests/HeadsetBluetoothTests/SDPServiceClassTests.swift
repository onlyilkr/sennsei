import Foundation
import Testing
import HeadsetCore
@testable import HeadsetBluetooth

private func bytes(_ hex: String) -> Data {
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        data.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return data
}

private let gaiaBytes = bytes("a2129ff3081b4c458afe469d9c4842ec")
private let iap2Bytes = bytes("00000000decafadedecadeafdecacaff")
private let hfBytes = bytes("0000111e00001000800000805f9b34fb")
private let otherBytes = bytes("00001203000010008000" + "00805f9b34fb")

@Test func bareUUIDElementYieldsOneUUID() {
    #expect(SDPServiceClass.uuidStrings(from: .uuid(gaiaBytes)) == ["a2129ff3-081b-4c45-8afe-469d9c4842ec"])
}

@Test func sequenceOfUUIDsYieldsAll() {
    let shape = SDPElementShape.sequence([.uuid(hfBytes), .uuid(otherBytes)])
    #expect(SDPServiceClass.uuidStrings(from: shape) == [
        "0000111e-0000-1000-8000-00805f9b34fb", "00001203-0000-1000-8000-00805f9b34fb",
    ])
}

@Test func unknownShapeYieldsEmptyList() {
    #expect(SDPServiceClass.uuidStrings(from: .other).isEmpty)
    #expect(SDPServiceClass.uuidStrings(from: nil).isEmpty)
    #expect(SDPServiceClass.uuidStrings(from: .sequence([.other])).isEmpty)
}

private func record(_ uuid: Data?, _ channel: UInt8?) -> SDPRecordSummary {
    SDPRecordSummary(serviceUUIDs: SDPServiceClass.uuidStrings(from: uuid.map { .uuid($0) }), rfcommChannel: channel)
}

@Test func gaiaBytesPickChannel15IgnoringIap2AndOthers() throws {
    let records = [record(iap2Bytes, 14), record(hfBytes, 10), record(gaiaBytes, 15)]
    #expect(try GaiaServiceLocator.channel(in: records) == 15)
}

@Test func fullDeviceShapePicksChannel15() throws {
    let records = [
        record(bytes("00001200" + "00001000800000805f9b34fb"), nil),
        record(bytes("0000110a" + "00001000800000805f9b34fb"), nil),
        record(iap2Bytes, 14),
        record(hfBytes, 10),
        record(otherBytes, 10),
        record(gaiaBytes, 15),
        record(nil, nil),
        record(bytes("0000110c" + "00001000800000805f9b34fb"), nil),
    ]
    #expect(try GaiaServiceLocator.channel(in: records) == 15)
}
