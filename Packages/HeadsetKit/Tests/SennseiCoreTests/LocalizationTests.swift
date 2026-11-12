import Foundation
import HeadsetCore
import Testing
@testable import SennseiCore

@Suite struct LocalizationTests {
    @Test func everyKeyHasEnglishAndTurkishText() {
        for key in Strings.allKeys {
            let en = Strings.text(key, locale: Locale(identifier: "en"))
            let tr = Strings.text(key, locale: Locale(identifier: "tr"))
            #expect(en != key, "missing en: \(key)"); #expect(tr != key, "missing tr: \(key)")
            #expect(!en.isEmpty && !tr.isEmpty)
        }
    }
    @Test func turkishDiffersFromEnglishForTheTerms() {
        let tr = Locale(identifier: "tr")
        #expect(Strings.text("noise.title", locale: tr) == "Gürültü kontrolü")
        #expect(Strings.text("noise.transparency", locale: tr) == "Şeffaf mod")
        #expect(Strings.text("eq.title", locale: tr) == "Ekolayzır")
        #expect(Strings.text("action.quit", locale: tr) == "Çık")
    }
    @Test func pauseInTransparencyKeyIsInEnglishAndTurkish() {
        #expect(Strings.allKeys.contains("noise.pauseInTransparency"))
        #expect(Strings.text("noise.pauseInTransparency", locale: Locale(identifier: "en")) == "Pause music in Transparency")
        #expect(Strings.text("noise.pauseInTransparency", locale: Locale(identifier: "tr")) == "Şeffaf modda müziği duraklat")
    }
    @Test func unknownLocaleFallsBackToEnglish() {
        #expect(Strings.text("noise.off", locale: Locale(identifier: "de")) == Strings.text("noise.off", locale: Locale(identifier: "en")))
        #expect(Strings.text("noise.off", locale: Locale(identifier: "en")) == "Off")
    }
    @Test func messagesCoverEveryErrorKeyTheModelProduces() {
        for key in ["error.notConnected", "error.timeout", "error.readBack", "error.readOnly", "error.unsupported", "error.bluetooth", "error.connect", "error.link", "error.other"] {
            #expect(Strings.message(UserMessage(key: key, argument: nil), locale: Locale(identifier: "en")) != key)
        }
    }
    @Test func availabilityTextsAreDistinct() {
        let en = Locale(identifier: "en")
        let all: [EQAvailability] = [.needsFirmwareUpdate(minimum: "2.12.0"), .audioModeNotEqualizer, .readOnlyModel, .unsupportedGeneration]
        #expect(Set(all.map { Strings.eqAvailability($0, locale: en) }).count == 4)
        #expect(Strings.eqAvailability(.available, locale: en) == "")
    }
}

@Suite struct LocalizationCoverageTests {
    private static let en = Locale(identifier: "en"), tr = Locale(identifier: "tr")
    private static let sameInBoth: Set<String> = ["app.name", "noise.anc", "eq.preset.Rock", "eq.preset.Pop", "eq.preset.Hip-Hop"]

    @Test func allKeysEqualsTheCatalogKeySet() {
        let catalog = Strings.Catalog(bundle: Bundle.module)
        #expect(Set(Strings.allKeys) == Set(catalog.strings.keys))
        #expect(Strings.allKeys.count == Set(Strings.allKeys).count)
    }
    @Test func everyPresetHasALabelKey() {
        for preset in EQPresets.accentum { #expect(Strings.allKeys.contains("eq.preset.\(preset.name)"), "\(preset.name)") }
    }
    @Test func everyErrorKeyTheModelProducesIsListed() {
        for key in UserMessage.ErrorKey.all { #expect(Strings.allKeys.contains(key)) }
    }
    @Test func englishAndTurkishDifferExceptAllowlist() {
        for key in Strings.allKeys where !Self.sameInBoth.contains(key) {
            #expect(Strings.text(key, locale: Self.en) != Strings.text(key, locale: Self.tr), "same text: \(key)")
        }
    }
    @Test func findsTheBundleInsideAnAppShapedDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "sennsei-\(UUID().uuidString)")
        let app = root.appending(path: "Test.app")
        let resources = app.appending(path: "Contents/Resources")
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>test.app</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>"
            .write(to: app.appending(path: "Contents/Info.plist"), atomically: true, encoding: .utf8)
        let name = Strings.resourceBundleName + ".bundle"
        try fm.copyItem(at: Bundle.module.bundleURL, to: resources.appending(path: name))
        defer { try? fm.removeItem(at: root) }

        let appBundle = try #require(Bundle(url: app))
        let found = try #require(Strings.findBundle(in: appBundle))
        #expect(found.bundleURL.lastPathComponent == name)
        #expect(found.bundleURL.deletingLastPathComponent().lastPathComponent == "Resources")
        #expect(Strings.Catalog(bundle: found).text("action.quit", locale: Self.tr) == "Çık")
        #expect(Strings.findBundle(in: Bundle(url: root.deletingLastPathComponent()) ?? .main) == nil)
    }
}
