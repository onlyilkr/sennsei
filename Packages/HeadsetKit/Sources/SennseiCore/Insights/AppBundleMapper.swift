import Foundation

public enum AppBundleMapper {
    /// The path from the root up to and including the first `.app` component, or nil when there is none.
    public static func outermostAppPath(forExecutablePath path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        for (index, part) in parts.enumerated() where part.count > 4 && part.hasSuffix(".app") {
            return parts[0...index].joined(separator: "/")
        }
        return nil
    }
}
