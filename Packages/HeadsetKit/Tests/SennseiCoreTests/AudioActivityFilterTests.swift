import Testing
@testable import SennseiCore

@Suite struct AudioActivityFilterTests {
    private let phones = RawAudioDevice(name: "ACCENTUM Wireless", transport: .bluetooth)
    private let usbPhones = RawAudioDevice(name: "ACCENTUM USB Audio", transport: .usb)
    private let speakers = RawAudioDevice(name: "MacBook Pro Speakers", transport: .builtIn)
    private let otherBT = RawAudioDevice(name: "Some Speaker", transport: .bluetooth)

    private func proc(
        _ pid: Int32, bundle: String? = nil, path: String? = nil,
        out: Bool = true, input: Bool = false, devices: [RawAudioDevice]
    ) -> RawAudioProcess {
        RawAudioProcess(pid: pid, bundleID: bundle, executablePath: path, outputRunning: out, inputRunning: input, outputDevices: devices)
    }

    private let chromeHelper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"

    private func resolver(_ path: String) -> (bundleID: String, name: String?)? {
        switch path {
        case "/Applications/Google Chrome.app": return ("com.google.Chrome", "Google Chrome")
        case "/Applications/Music.app": return ("com.apple.Music", "Music")
        default: return nil
        }
    }

    @Test func onlyProcessesOutputtingToTheHeadphonesAreKept() {
        let raw = [
            proc(1, bundle: "com.apple.Music", devices: [phones]),
            proc(2, bundle: "com.speaker", devices: [speakers]),
            proc(3, bundle: "com.other", devices: [otherBT]),
            proc(4, bundle: "com.usb", devices: [usbPhones]),
        ]
        let result = AudioActivityFilter.activities(from: raw, headphoneName: "ACCENTUM", resolveApp: resolver)
        #expect(result.map(\.bundleID) == ["com.apple.Music", "com.usb"])
        #expect(result.map(\.route) == [.bluetooth, .usb])
    }

    @Test func nonWirelessTransportWithMatchingNameIsIgnored() {
        let fake = RawAudioDevice(name: "ACCENTUM", transport: .other)
        let result = AudioActivityFilter.activities(from: [proc(1, bundle: "a.b", devices: [fake])], headphoneName: "accentum", resolveApp: resolver)
        #expect(result.isEmpty)
    }

    @Test func helperProcessesMapToTheirMainApp() {
        let raw = [proc(1, bundle: "com.google.Chrome.helper", path: chromeHelper, devices: [phones])]
        let result = AudioActivityFilter.activities(from: raw, headphoneName: "ACCENTUM", resolveApp: resolver)
        #expect(result == [ProcessActivity(bundleID: "com.google.Chrome", appName: "Google Chrome", outputRunning: true, inputRunning: false, route: .bluetooth)])
    }

    @Test func multipleProcessesOfOneAppMergeAndOrTheFlags() {
        let raw = [
            proc(1, bundle: "x", path: chromeHelper, out: true, input: false, devices: [phones]),
            proc(2, bundle: "y", path: chromeHelper, out: false, input: true, devices: [phones]),
        ]
        let result = AudioActivityFilter.activities(from: raw, headphoneName: "ACCENTUM", resolveApp: resolver)
        #expect(result.count == 1)
        #expect(result[0].outputRunning && result[0].inputRunning)
    }

    @Test func idleProcessesAndUnresolvableProcessesAreDropped() {
        let raw = [
            proc(1, bundle: "com.idle", out: false, input: false, devices: [phones]),
            proc(2, bundle: nil, path: "/usr/bin/afplay", devices: [phones]),
            proc(3, bundle: nil, path: "/Applications/Unknown.app/Contents/MacOS/u", devices: [phones]),
        ]
        #expect(AudioActivityFilter.activities(from: raw, headphoneName: "ACCENTUM", resolveApp: resolver).isEmpty)
    }

    @Test func unresolvableProcessFallsBackToOwnBundleID() {
        let raw = [
            proc(1, bundle: "com.own.tool", path: "/usr/local/bin/tool", devices: [phones]),
            proc(2, bundle: "com.own.app", path: "/Applications/Unknown.app/Contents/MacOS/u", devices: [phones]),
        ]
        let result = AudioActivityFilter.activities(from: raw, headphoneName: "ACCENTUM", resolveApp: resolver)
        #expect(result.map(\.bundleID) == ["com.own.tool", "com.own.app"])
        #expect(result.allSatisfy { $0.appName == nil })
    }

    @Test func headphoneNameMatchIsCaseInsensitive() {
        let raw = [proc(1, bundle: "a.b", devices: [RawAudioDevice(name: "My AccentUM Pro", transport: .bluetooth)])]
        #expect(AudioActivityFilter.activities(from: raw, headphoneName: "ACCENTUM", resolveApp: resolver).count == 1)
    }

    @Test func emptyHeadphoneNameMatchesNothing() {
        let raw = [proc(1, bundle: "a.b", devices: [phones])]
        #expect(AudioActivityFilter.activities(from: raw, headphoneName: "", resolveApp: resolver).isEmpty)
    }

    @Test func usbRouteWinsWhenAnAppUsesBothBluetoothAndUsb() {
        let raw = [
            proc(1, bundle: "com.apple.Music", devices: [phones]),
            proc(2, bundle: "com.apple.Music", devices: [phones, usbPhones]),
        ]
        let result = AudioActivityFilter.activities(from: raw, headphoneName: "ACCENTUM", resolveApp: resolver)
        #expect(result == [ProcessActivity(bundleID: "com.apple.Music", appName: nil, outputRunning: true, inputRunning: false, route: .usb)])
        let reversed = AudioActivityFilter.activities(from: raw.reversed(), headphoneName: "ACCENTUM", resolveApp: resolver)
        #expect(reversed.first?.route == .usb)
    }
}
