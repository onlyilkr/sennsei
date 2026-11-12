import Testing
@testable import HeadsetBluetooth

@Suite struct SDPDumpFormatterTests {
    @Test func formatsRecordWithNestedUUIDAndMissingAttribute() {
        let uuid = SDPElementDescription(
            typeDescriptor: 3, sizeDescriptor: 4, hasUUID: true,
            uuid16Hex: "a2129ff3081b4c458afe469d9c4842ec", uuid4Hex: nil, uuid2Hex: nil)
        let list = SDPElementDescription(
            typeDescriptor: 6, sizeDescriptor: 5, arrayCount: 1, arrayType: "__NSArrayM", children: [uuid])
        let record = SDPRecordDump(
            index: 2, rfcommChannel: 14, attributeKeys: [0x0001, 0x0004],
            attributes: [
                SDPAttributeDump(attributeID: 0x0001, name: "ServiceClassIDList", element: list),
                SDPAttributeDump(attributeID: 0x0100, name: "ServiceName", element: nil),
            ])
        let text = SDPDumpFormatter.format([record])
        #expect(text.contains("SDP dump: 1 record(s)"))
        #expect(text.contains("record 2: rfcommChannel=14"))
        #expect(text.contains("attributeKeys: 0x0001,0x0004"))
        #expect(text.contains("attribute 0x0001 (ServiceClassIDList):"))
        #expect(text.contains("type=6(sequence) size=5 array=__NSArrayM[1]"))
        #expect(text.contains("      type=3(uuid) size=4 array=nil uuid16=a2129ff3081b4c458afe469d9c4842ec uuid4=nil uuid2=nil"))
        #expect(text.contains("attribute 0x0100 (ServiceName): missing"))
    }

    @Test func marksInaccessibleKeysAndNoChannel() {
        let text = SDPDumpFormatter.format([SDPRecordDump(index: 0, rfcommChannel: nil, attributeKeys: nil, attributes: [])])
        #expect(text.contains("rfcommChannel=none"))
        #expect(text.contains("attributeKeys: inaccessible"))
    }
}
