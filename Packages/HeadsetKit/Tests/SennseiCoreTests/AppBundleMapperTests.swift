import Testing
@testable import SennseiCore

@Suite struct AppBundleMapperTests {
    @Test func helperInsideBundleMapsToOutermostApp() {
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        #expect(AppBundleMapper.outermostAppPath(forExecutablePath: path) == "/Applications/Google Chrome.app")
    }

    @Test func plainExecutableHasNoBundle() {
        #expect(AppBundleMapper.outermostAppPath(forExecutablePath: "/usr/bin/afplay") == nil)
    }

    @Test func simpleAppBundle() {
        #expect(AppBundleMapper.outermostAppPath(forExecutablePath: "/Applications/Safari.app/Contents/MacOS/Safari") == "/Applications/Safari.app")
    }

    @Test func emptyStringIsNil() {
        #expect(AppBundleMapper.outermostAppPath(forExecutablePath: "") == nil)
    }

    @Test func componentsThatMerelyStartWithAppDoNotMatch() {
        #expect(AppBundleMapper.outermostAppPath(forExecutablePath: "/x/foo.application/bar") == nil)
        #expect(AppBundleMapper.outermostAppPath(forExecutablePath: "/x/foo.apple/bar") == nil)
    }

    @Test func trailingSlashAfterBundleIsStripped() {
        #expect(AppBundleMapper.outermostAppPath(forExecutablePath: "/Applications/Safari.app/") == "/Applications/Safari.app")
    }

    @Test func extensionMatchIsCaseSensitive() {
        #expect(AppBundleMapper.outermostAppPath(forExecutablePath: "/Applications/Safari.App/Contents/MacOS/Safari") == nil)
    }

    @Test func relativePathsMapToTheirBundle() {
        #expect(AppBundleMapper.outermostAppPath(forExecutablePath: "Foo.app/Contents/MacOS/foo") == "Foo.app")
    }

    @Test func bareDotAppHasNoName() {
        #expect(AppBundleMapper.outermostAppPath(forExecutablePath: "/Applications/.app") == nil)
    }
}
