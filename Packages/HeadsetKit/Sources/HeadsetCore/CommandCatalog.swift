import Foundation
import GaiaProtocol

public enum CommandAccess: Sendable { case get, set }
public enum CommandStatus: Sendable { case verified, needsHardwareTest, blocked }
public enum PayloadRule: Sendable { case empty, exact(Int), lengths(ClosedRange<Int>) }
public enum SendMode: Sendable { case readOnly, readWrite }

public struct CommandSpec: Sendable {
    public let vendor: UInt16
    public let id: UInt16
    public let name: String
    public let access: CommandAccess
    public let payload: PayloadRule
    public let minFirmware: FirmwareVersion?
    /// Exclusive upper bound: the spec applies to firmware strictly below this version.
    public let maxFirmwareExclusive: FirmwareVersion?
    public let status: CommandStatus

    public init(
        vendor: UInt16, id: UInt16, name: String, access: CommandAccess,
        payload: PayloadRule, minFirmware: FirmwareVersion? = nil,
        maxFirmwareExclusive: FirmwareVersion? = nil, status: CommandStatus
    ) {
        self.vendor = vendor
        self.id = id
        self.name = name
        self.access = access
        self.payload = payload
        self.minFirmware = minFirmware
        self.maxFirmwareExclusive = maxFirmwareExclusive
        self.status = status
    }
}

public enum CatalogError: Error, Equatable {
    case unknownCommand(UInt16, UInt16)
    case blocked(String)
    case writeNotAllowed(String)
    case badPayload(String)
    case firmwareTooOld(String)
    case unverifiedWrite(String)
}

extension CommandSpec {
    /// Whether this spec applies to `firmware`. With an unknown firmware only specs without
    /// any bound apply.
    fileprivate func covers(_ firmware: FirmwareVersion?) -> Bool {
        guard let firmware else { return minFirmware == nil && maxFirmwareExclusive == nil }
        if let minFirmware, firmware < minFirmware { return false }
        if let maxFirmwareExclusive, firmware >= maxFirmwareExclusive { return false }
        return true
    }

    /// Half-open `[min, max)` ranges; nil min is 0.0.0, nil max is unbounded.
    fileprivate func overlaps(_ other: CommandSpec) -> Bool {
        let low = minFirmware ?? FirmwareVersion(0, 0, 0)
        let otherLow = other.minFirmware ?? FirmwareVersion(0, 0, 0)
        let startsBeforeOtherEnds = other.maxFirmwareExclusive.map { low < $0 } ?? true
        let otherStartsBeforeEnd = maxFirmwareExclusive.map { otherLow < $0 } ?? true
        return startsBeforeOtherEnds && otherStartsBeforeEnd
    }
}

/// The single gate every outgoing frame must pass.
public struct CommandCatalog: Sendable {
    private let table: [UInt32: [CommandSpec]]
    public let allSpecs: [CommandSpec]

    public init(_ specs: [CommandSpec]) {
        self.init(specs, reportDuplicates: true)
    }

    /// Several specs may share a (vendor, id) only when their firmware ranges are disjoint and
    /// none is blocked; anything else is a programming error (asserted in debug when
    /// `reportDuplicates`). A blocked spec always wins in `validate`, whatever else shares its id.
    init(_ specs: [CommandSpec], reportDuplicates: Bool) {
        allSpecs = specs
        let grouped = Dictionary(grouping: specs) { Self.key($0.vendor, $0.id) }
        var illegitimate = false
        for group in grouped.values where group.count > 1 {
            if group.contains(where: { $0.status == .blocked }) { illegitimate = true }
            for i in group.indices {
                for j in group.indices where j > i && group[i].overlaps(group[j]) { illegitimate = true }
            }
        }
        if illegitimate && reportDuplicates {
            assertionFailure("CommandCatalog: duplicate (vendor, id) entries with overlapping ranges or a blocked entry")
        }
        // Dictionary(grouping:) keeps the original order within each group.
        table = grouped
    }

    private static func key(_ vendor: UInt16, _ id: UInt16) -> UInt32 {
        UInt32(vendor) << 16 | UInt32(id)
    }

    public func specs(vendor: UInt16, id: UInt16) -> [CommandSpec] {
        table[Self.key(vendor, id)] ?? []
    }

    public func spec(vendor: UInt16, id: UInt16) -> CommandSpec? {
        let all = specs(vendor: vendor, id: id)
        return all.first(where: { $0.status == .blocked }) ?? all.first
    }

    public func validate(
        _ frame: GaiaFrame, firmware: FirmwareVersion?, mode: SendMode, allowUnverifiedWrites: Bool = false
    ) throws(CatalogError) {
        let candidates = specs(vendor: frame.vendor, id: frame.command)
        guard let first = candidates.first else {
            throw .unknownCommand(frame.vendor, frame.command)
        }
        if let blocked = candidates.first(where: { $0.status == .blocked }) { throw .blocked(blocked.name) }
        guard let spec = candidates.first(where: { $0.covers(firmware) }) else {
            throw .firmwareTooOld(first.name)
        }
        if mode == .readOnly && spec.access == .set { throw .writeNotAllowed(spec.name) }
        if spec.access == .set && spec.status == .needsHardwareTest && !allowUnverifiedWrites {
            throw .unverifiedWrite(spec.name)
        }
        let count = frame.payload.count
        let payloadOK = switch spec.payload {
        case .empty: count == 0
        case .exact(let n): count == n
        case .lengths(let range): range.contains(count)
        }
        if !payloadOK { throw .badPayload(spec.name) }
    }
}
