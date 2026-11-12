import HeadsetCore

/// What the locator needs to know about one SDP service record.
public struct SDPRecordSummary: Equatable, Sendable {
    public let serviceUUIDs: [String]
    public let rfcommChannel: UInt8?

    public init(serviceUUIDs: [String], rfcommChannel: UInt8?) {
        self.serviceUUIDs = serviceUUIDs
        self.rfcommChannel = rfcommChannel
    }
}

/// Finds the GAIA RFCOMM channel by service class UUID only.
/// Never falls back to a name, a record position or a fixed channel number.
public enum GaiaServiceLocator {
    public static let gaiaUUID = "a2129ff3-081b-4c45-8afe-469d9c4842ec"

    /// iAP2 (iPhone accessory) service UUID: a record that also lists it is never treated as GAIA.
    public static let iap2UUID = "00000000-deca-fade-deca-deafdecacaff"

    public static func channel(in records: [SDPRecordSummary]) throws(TransportError) -> UInt8 {
        for record in records {
            let uuids = record.serviceUUIDs.map { $0.lowercased() }
            guard let channel = record.rfcommChannel,
                  uuids.contains(gaiaUUID),
                  !uuids.contains(iap2UUID)
            else { continue }
            return channel
        }
        throw .gaiaServiceNotFound
    }
}
