import Foundation

/// Plain-data description of one SDP data element, extracted from IOBluetooth by `RFCOMMTransport`
/// and rendered by `SDPDumpFormatter`. Pure so the formatting can be unit-tested.
public struct SDPElementDescription: Sendable, Equatable {
    public var typeDescriptor: UInt8
    public var sizeDescriptor: UInt8
    /// Count of `getArrayValue()` entries; nil when the call returned nil.
    public var arrayCount: Int?
    /// Class name of the `getArrayValue()` result; nil when it returned nil.
    public var arrayType: String?
    public var hasUUID: Bool
    public var uuid16Hex: String?
    public var uuid4Hex: String?
    public var uuid2Hex: String?
    public var number: String?
    public var string: String?
    public var dataLength: Int?
    public var valueDescription: String?
    public var children: [SDPElementDescription]

    public init(
        typeDescriptor: UInt8, sizeDescriptor: UInt8, arrayCount: Int? = nil, arrayType: String? = nil,
        hasUUID: Bool = false, uuid16Hex: String? = nil, uuid4Hex: String? = nil, uuid2Hex: String? = nil,
        number: String? = nil, string: String? = nil, dataLength: Int? = nil,
        valueDescription: String? = nil, children: [SDPElementDescription] = []
    ) {
        self.typeDescriptor = typeDescriptor
        self.sizeDescriptor = sizeDescriptor
        self.arrayCount = arrayCount
        self.arrayType = arrayType
        self.hasUUID = hasUUID
        self.uuid16Hex = uuid16Hex
        self.uuid4Hex = uuid4Hex
        self.uuid2Hex = uuid2Hex
        self.number = number
        self.string = string
        self.dataLength = dataLength
        self.valueDescription = valueDescription
        self.children = children
    }
}

public struct SDPAttributeDump: Sendable, Equatable {
    public var attributeID: UInt16
    public var name: String
    /// nil when the record has no such attribute.
    public var element: SDPElementDescription?

    public init(attributeID: UInt16, name: String, element: SDPElementDescription?) {
        self.attributeID = attributeID
        self.name = name
        self.element = element
    }
}

public struct SDPRecordDump: Sendable, Equatable {
    public var index: Int
    public var rfcommChannel: UInt8?
    /// Attribute IDs present in `record.attributes`; nil when the dictionary is not accessible.
    public var attributeKeys: [UInt16]?
    public var attributes: [SDPAttributeDump]

    public init(index: Int, rfcommChannel: UInt8?, attributeKeys: [UInt16]?, attributes: [SDPAttributeDump]) {
        self.index = index
        self.rfcommChannel = rfcommChannel
        self.attributeKeys = attributeKeys
        self.attributes = attributes
    }
}

public enum SDPDumpFormatter {
    public static func typeName(_ descriptor: UInt8) -> String {
        switch descriptor {
        case 0: "nil"
        case 1: "uint"
        case 2: "int"
        case 3: "uuid"
        case 4: "string"
        case 5: "bool"
        case 6: "sequence"
        case 7: "alternative"
        case 8: "url"
        default: "unknown"
        }
    }

    public static func format(_ records: [SDPRecordDump]) -> String {
        var lines = ["SDP dump: \(records.count) record(s)"]
        for record in records {
            lines.append("")
            lines.append("record \(record.index): rfcommChannel=\(record.rfcommChannel.map(String.init) ?? "none")")
            let keys = record.attributeKeys.map { $0.map { String(format: "0x%04x", $0) }.joined(separator: ",") } ?? "inaccessible"
            lines.append("  attributeKeys: \(keys)")
            for attribute in record.attributes {
                let header = String(format: "  attribute 0x%04x (%@):", attribute.attributeID, attribute.name)
                if let element = attribute.element {
                    lines.append(header)
                    lines.append(contentsOf: format(element, indent: 4))
                } else {
                    lines.append(header + " missing")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func format(_ e: SDPElementDescription, indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        var parts = ["type=\(e.typeDescriptor)(\(typeName(e.typeDescriptor)))", "size=\(e.sizeDescriptor)"]
        if let count = e.arrayCount {
            parts.append("array=\(e.arrayType ?? "?")[\(count)]")
        } else {
            parts.append("array=nil")
        }
        if e.hasUUID {
            parts.append("uuid16=\(e.uuid16Hex ?? "nil")")
            parts.append("uuid4=\(e.uuid4Hex ?? "nil")")
            parts.append("uuid2=\(e.uuid2Hex ?? "nil")")
        } else {
            parts.append("uuid=nil")
        }
        parts.append("number=\(e.number ?? "nil")")
        if let string = e.string { parts.append("string=\"\(string)\"") }
        parts.append("data=\(e.dataLength.map { "\($0)B" } ?? "nil")")
        parts.append("value=\(e.valueDescription ?? "nil")")
        var lines = [pad + parts.joined(separator: " ")]
        for child in e.children {
            lines.append(contentsOf: format(child, indent: indent + 2))
        }
        return lines
    }
}
