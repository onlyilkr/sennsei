import Foundation

public protocol AudioActivitySource: Sendable {
    func snapshot() async -> [ProcessActivity]
}

public enum Transport: Sendable, Equatable { case bluetooth, usb, builtIn, other }

public struct RawAudioDevice: Equatable, Sendable {
    public var name: String
    public var transport: Transport

    public init(name: String, transport: Transport) {
        self.name = name
        self.transport = transport
    }
}

public struct RawAudioProcess: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String?
    public var executablePath: String?
    public var outputRunning: Bool
    public var inputRunning: Bool
    public var outputDevices: [RawAudioDevice]

    public init(
        pid: Int32, bundleID: String?, executablePath: String?,
        outputRunning: Bool, inputRunning: Bool, outputDevices: [RawAudioDevice]
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.executablePath = executablePath
        self.outputRunning = outputRunning
        self.inputRunning = inputRunning
        self.outputDevices = outputDevices
    }
}

/// Used below macOS 14.2, where per-process audio objects do not exist.
public struct UnavailableAudioActivitySource: AudioActivitySource {
    public init() {}
    public var isSupported: Bool { false }
    public func snapshot() async -> [ProcessActivity] { [] }
}

public enum AudioActivityFilter {
    /// Keeps processes playing or recording through the named wireless/USB headphones, maps helpers to their
    /// outermost app and merges all processes of one app (flags are OR-ed).
    public static func activities(
        from raw: [RawAudioProcess],
        headphoneName: String,
        resolveApp: (String) -> (bundleID: String, name: String?)?
    ) -> [ProcessActivity] {
        guard !headphoneName.isEmpty else { return [] }
        var order: [String] = []
        var merged: [String: ProcessActivity] = [:]

        for process in raw {
            guard process.outputRunning || process.inputRunning else { continue }
            let matching = process.outputDevices.filter {
                ($0.transport == .bluetooth || $0.transport == .usb)
                    && $0.name.localizedCaseInsensitiveContains(headphoneName)
            }
            guard !matching.isEmpty else { continue }
            // Route rule: USB wins over Bluetooth, both within one process and when merging an app's processes.
            let route: AudioRoute = matching.contains { $0.transport == .usb } ? .usb : .bluetooth

            var bundleID: String?
            var appName: String?
            if let path = process.executablePath,
               let appPath = AppBundleMapper.outermostAppPath(forExecutablePath: path),
               let resolved = resolveApp(appPath) {
                bundleID = resolved.bundleID
                appName = resolved.name
            } else {
                bundleID = process.bundleID
            }
            guard let id = bundleID, !id.isEmpty else { continue }

            if var existing = merged[id] {
                existing.outputRunning = existing.outputRunning || process.outputRunning
                existing.inputRunning = existing.inputRunning || process.inputRunning
                if existing.appName == nil { existing.appName = appName }
                if route == .usb { existing.route = .usb }
                merged[id] = existing
            } else {
                order.append(id)
                merged[id] = ProcessActivity(
                    bundleID: id, appName: appName,
                    outputRunning: process.outputRunning, inputRunning: process.inputRunning, route: route
                )
            }
        }
        return order.compactMap { merged[$0] }
    }
}
