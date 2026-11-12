import Foundation

public struct SceneLoadResult: Equatable, Sendable {
    public let scenes: [Scene]
    public let usedDefaults: Bool
    public let fileWasCorrupt: Bool
}

public struct SceneStore: Sendable {
    private let url: URL

    public init(url: URL) { self.url = url }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Sennsei", isDirectory: true).appendingPathComponent("scenes.json")
    }

    /// Never writes: a missing or corrupt file yields the defaults and the file is left as is.
    public func load() -> SceneLoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SceneLoadResult(scenes: Scene.defaults, usedDefaults: true, fileWasCorrupt: false)
        }
        do {
            let data = try Data(contentsOf: url)
            let scenes = try JSONDecoder().decode([Scene].self, from: data)
            return SceneLoadResult(scenes: scenes, usedDefaults: false, fileWasCorrupt: false)
        } catch {
            return SceneLoadResult(scenes: Scene.defaults, usedDefaults: true, fileWasCorrupt: true)
        }
    }

    public func save(_ scenes: [Scene]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(scenes).write(to: url, options: .atomic)
    }
}
