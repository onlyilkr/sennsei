import Foundation

public enum EQVerificationError: Error, Equatable {
    case missingSnapshot
    case snapshotFirmwareMismatch(String, String)
    case badGains(String)
    case session(SessionError)
}

/// Steps of the Gen1 device verification. Writes go only through `HeadsetSession.writeEQ`.
public enum EQVerification {
    /// Exactly five comma-separated numbers, each within -6...+6.
    public static func parseGains(_ text: String) throws(EQVerificationError) -> [Double] {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let values = parts.compactMap { Double($0) }
        guard parts.count == 5, values.count == 5, values.allSatisfy({ $0.isFinite && $0 >= -6 && $0 <= 6 }) else { throw .badGains(text) }
        return values
    }

    public static func read(_ s: HeadsetSession) async throws(EQVerificationError) -> EQSnapshot {
        do { return try await s.readEQ() } catch { throw .session(error) }
    }

    public static func write(
        _ s: HeadsetSession, gains: [Double], bassBoost: Bool, snapshot: EQSnapshot?
    ) async throws(EQVerificationError) -> (before: EQSnapshot, after: EQSnapshot) {
        guard let snapshot else { throw .missingSnapshot }
        try await checkFirmware(s, snapshot)
        let before = try await read(s)
        do {
            let after = try await s.writeEQ(gains: gains, bassBoost: bassBoost)
            return (before, after)
        } catch { throw .session(error) }
    }

    /// Writes the snapshot's gains back; an unconfigured snapshot (or one without gains) restores a flat EQ, bass off.
    public static func restore(_ s: HeadsetSession, snapshot: EQSnapshot?) async throws(EQVerificationError) -> EQSnapshot {
        guard let snapshot else { throw .missingSnapshot }
        try await checkFirmware(s, snapshot)
        let gains: [Double]
        let bass: Bool
        if !snapshot.isUnconfigured, let g = snapshot.gains {
            gains = g
            bass = snapshot.bassBoost ?? false
        } else {
            gains = [0, 0, 0, 0, 0]
            bass = false
        }
        do { return try await s.writeEQ(gains: gains, bassBoost: bass) } catch { throw .session(error) }
    }

    private static func checkFirmware(_ s: HeadsetSession, _ snapshot: EQSnapshot) async throws(EQVerificationError) {
        guard let device = await s.state?.profile.firmware.description else { throw .session(.notConnected) }
        if device != snapshot.firmware { throw .snapshotFirmwareMismatch(snapshot.firmware, device) }
    }
}
