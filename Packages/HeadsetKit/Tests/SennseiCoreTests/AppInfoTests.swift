import Foundation
import Testing
@testable import SennseiCore

@Suite struct AppInfoTests {
    @Test func bundleIdentifierMatchesInfoPlist() throws {
        // …/Packages/HeadsetKit/Tests/SennseiCoreTests/AppInfoTests.swift -> repo root is five levels up.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let plistURL = root.appendingPathComponent("Tools/app/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["CFBundleIdentifier"] as? String == AppInfo.bundleIdentifier)
    }
}
