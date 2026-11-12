import Foundation
import RemoteProtocol
import SennseiControl
import Testing

@testable import SennseiCLICore

private func parsed(_ args: [String]) -> CLICommand? {
    if case .success(let c) = CLICommand.parse(args) { return c }
    return nil
}

@Suite struct CLICommandTests {
    @Test func parsesTheDocumentedCommands() {
        #expect(parsed(["noise", "anc"]) == .send(RemoteRequest(cmd: "noise", arg: "anc")))
        #expect(parsed(["noise", "transparency"]) == .send(RemoteRequest(cmd: "noise", arg: "transparency")))
        #expect(parsed(["noise", "next"]) == .send(RemoteRequest(cmd: "noise", arg: "next")))
        #expect(parsed(["anc", "on"]) == .send(RemoteRequest(cmd: "noise", arg: "anc")))
        #expect(parsed(["anc", "off"]) == .send(RemoteRequest(cmd: "noise", arg: "off")))
        #expect(parsed(["pause", "on"]) == .send(RemoteRequest(cmd: "pause", arg: "on")))
        #expect(parsed(["eq", "Bass Boost"]) == .send(RemoteRequest(cmd: "eq", arg: "Bass Boost")))
        #expect(parsed(["eq", "next"]) == .send(RemoteRequest(cmd: "eq", arg: "next")))
        #expect(parsed(["scene", "focus"]) == .send(RemoteRequest(cmd: "scene", arg: "focus")))
        #expect(parsed(["auto", "off"]) == .send(RemoteRequest(cmd: "auto", arg: "off")))
        #expect(parsed(["status"]) == .send(RemoteRequest(cmd: "status")))
        #expect(parsed(["status", "--json"]) == .send(RemoteRequest(cmd: "status"), style: .json))
        #expect(parsed(["battery"]) == .send(RemoteRequest(cmd: "status"), style: .battery))
        #expect(parsed(["doctor"]) == .doctor)
        #expect(parsed(["--help"]) == .help)
        #expect(parsed(["--version"]) == .version)
    }

    @Test func rejectsUsageErrorsWithExitCode2() {
        let bad: [[String]] = [
            [], ["bogus"], ["noise"], ["noise", "loud"], ["anc", "maybe"], ["anc"], ["pause", "x"],
            ["status", "extra"], ["status", "--xml"], ["noise", "anc", "extra"], ["eq"], ["scene"],
            ["battery", "x"], ["doctor", "x"],
        ]
        for args in bad {
            guard case .failure(let e) = CLICommand.parse(args) else {
                Issue.record("expected failure for \(args)")
                continue
            }
            #expect(e.exitCode == 2)
            #expect(!e.message.isEmpty)
        }
    }

    @Test func exitCodesFollowTheContract() {
        let request = RemoteRequest(cmd: "noise", arg: "anc")
        let ok = CLIOutput.render(RemoteResponse(ok: true), for: request)
        #expect(ok.exitCode == 0)
        let failed = CLIOutput.render(
            RemoteResponse(ok: false, error: RemoteError(code: .failed, message: "link lost")), for: request)
        #expect(failed.exitCode == 1)
        #expect(failed.stderr.contains("link lost"))
        #expect(failed.stdout.isEmpty)
        let warned = CLIOutput.render(RemoteResponse(ok: true, warning: "slow"), for: request)
        #expect(warned.exitCode == 0)
        #expect(warned.stderr.contains("slow"))

        let notRunning = CLIOutput.render(error: ControlClientError.appNotRunning)
        #expect(notRunning.exitCode == 3)
        #expect(notRunning.stderr.contains("Sennsei is not running"))
        let timedOut = CLIOutput.render(error: ControlClientError.timedOut)
        #expect(timedOut.exitCode == 4)
        #expect(!timedOut.stderr.isEmpty)
        #expect(CLIOutput.render(error: ControlClientError.protocolError("x")).exitCode == 1)
    }

    @Test func batteryPrintsOnlyThePercentOrUnknown() {
        let req = RemoteRequest(cmd: "status")
        let known = RemoteResponse(
            ok: true, status: RemoteStatus(connected: true, battery: 63, automaticScenes: false, appVersion: "1.0"))
        #expect(CLIOutput.render(known, for: req, style: .battery).stdout == "63\n")
        let unknown = RemoteResponse(
            ok: true, status: RemoteStatus(connected: true, automaticScenes: false, appVersion: "1.0"))
        #expect(CLIOutput.render(unknown, for: req, style: .battery).stdout == "unknown\n")
    }

    @Test func statusPrintsHumanLinesAndJSONPrintsTheRawResponse() throws {
        let req = RemoteRequest(cmd: "status")
        let response = RemoteResponse(
            ok: true,
            status: RemoteStatus(
                connected: true, battery: 63, noise: "anc", pauseInTransparency: false, eqPreset: "Flat",
                activeScene: "focus", automaticScenes: true, appVersion: "1.2"))
        let human = CLIOutput.render(response, for: req)
        #expect(human.stdout.contains("Headset: connected"))
        #expect(human.stdout.contains("Battery: 63%"))
        #expect(human.stdout.contains("Noise control: anc"))
        #expect(human.stdout.contains("Automatic scenes: on"))
        #expect(human.exitCode == 0)

        let json = CLIOutput.render(response, for: req, style: .json)
        let decoded: RemoteResponse? = RemoteWire.decodeLine(Data(json.stdout.utf8))
        #expect(decoded == response)
    }

    @Test func doctorReportsEachCheckAndFailsWhenTheAppIsNotRunning() {
        let url = URL(fileURLWithPath: "/tmp/sennsei-cli-test-\(UUID().uuidString.prefix(8)).sock")
        let result = CLIDoctor.run(socketURL: url)
        #expect(result.exitCode == 1)
        #expect(result.report.contains("socket: fail"))
        #expect(result.report.contains("app: fail"))
        #expect(result.report.contains("headset: fail"))
        #expect(result.report.contains("battery: fail"))
    }

    @Test func cliTargetDoesNotLinkBluetoothOrSennseiCore() throws {
        let manifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        let forbidden = ["SennseiCore", "HeadsetBluetooth", "HeadsetCore"]
        var checked = 0
        for line in text.split(separator: "\n") where line.contains("\"SennseiCLICore\"") || line.contains("\"SennseiCLI\"") {
            if line.contains("name: \"SennseiCLICore\"") || line.contains("name: \"SennseiCLI\"") {
                checked += 1
                for f in forbidden { #expect(!line.contains("\"\(f)\""), "\(line) mentions \(f)") }
            }
        }
        #expect(checked == 2)
    }

    private static let evil = "x\u{1B}[2Jy\rz\u{08}\u{7F}\u{9B}"
    private func hasControls(_ t: String) -> Bool {
        t.unicodeScalars.contains { ($0.value < 0x20 && $0 != "\n") || (0x7F...0x9F).contains($0.value) }
    }

    @Test func humanOutputNeverContainsControlCharacters() {
        let evil = Self.evil
        let status = RemoteResponse(
            ok: true,
            status: RemoteStatus(
                connected: true, noise: evil, eqPreset: evil, activeScene: evil, automaticScenes: true, appVersion: evil),
            warning: evil)
        let req = RemoteRequest(cmd: "status")
        let r = CLIOutput.render(status, for: req)
        #expect(!hasControls(r.stdout) && !hasControls(r.stderr))
        #expect(r.stdout.contains("x?[2Jy?z"))
        let err = CLIOutput.render(
            RemoteResponse(ok: false, error: RemoteError(code: .unknownPreset, message: evil)), for: req)
        #expect(!hasControls(err.stderr))
        #expect(!hasControls(CLIOutput.render(error: .protocolError(evil)).stderr))
        // The JSON path stays raw JSON (escaped by the encoder).
        let json = CLIOutput.render(status, for: req, style: .json)
        #expect(!json.stdout.dropLast().contains("\n"))
        #expect(CLIRunner.run(["bogus" + evil]).stderr.unicodeScalars.allSatisfy { !($0.value == 0x1B) })
    }

    @Test func doctorSanitizesTheReplyError() throws {
        let dir = URL(fileURLWithPath: "/tmp/sn-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("c.sock")
        let server = ControlServer(socketURL: url) { _ in
            RemoteResponse(ok: false, error: RemoteError(code: .failed, message: Self.evil))
        }
        try server.start()
        defer { server.stop() }
        let result = CLIDoctor.run(socketURL: url)
        #expect(result.report.contains("app: fail"))
        #expect(!hasControls(result.report))
    }

    @Test func versionComesFromOneValueSharedWithDoctorAndInfoPlist() throws {
        #expect(CLIRunner.run(["--version"]).stdout == "sennsei \(CLIVersion.current)\n")
        let doctor = CLIDoctor.run(socketURL: URL(fileURLWithPath: "/tmp/none-\(UUID().uuidString.prefix(6)).sock"))
        #expect(doctor.report.contains("cli \(CLIVersion.current)"))
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/app/Info.plist")
        let dict = try #require(NSDictionary(contentsOf: plist))
        #expect(dict["CFBundleShortVersionString"] as? String == CLIVersion.current)
    }
}
