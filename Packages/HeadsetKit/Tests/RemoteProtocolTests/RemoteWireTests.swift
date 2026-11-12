import Foundation
import RemoteProtocol
import Testing

@Test func parsesEveryCommand() {
    #expect(RemoteRequest(cmd: "noise", arg: "anc").parsed == .success(.noise(.mode("anc"))))
    #expect(RemoteRequest(cmd: "noise", arg: "next").parsed == .success(.noise(.next)))
    #expect(RemoteRequest(cmd: "pause", arg: "off").parsed == .success(.pause(false)))
    #expect(RemoteRequest(cmd: "eq", arg: "Rock").parsed == .success(.eq(.preset("Rock"))))
    #expect(RemoteRequest(cmd: "eq", arg: "next").parsed == .success(.eq(.next)))
    #expect(RemoteRequest(cmd: "scene", arg: "focus").parsed == .success(.scene("focus")))
    #expect(RemoteRequest(cmd: "auto", arg: "on").parsed == .success(.automaticScenes(true)))
    #expect(RemoteRequest(cmd: "status", arg: nil).parsed == .success(.status))
    #expect(RemoteRequest(cmd: "ping", arg: nil).parsed == .success(.ping))
}

@Test func rejectsUnknownCommandsAndBadArguments() {
    for r in [
        RemoteRequest(cmd: "flash", arg: nil), .init(cmd: "noise", arg: "loud"), .init(cmd: "noise", arg: nil),
        .init(cmd: "pause", arg: "maybe"), .init(cmd: "scene", arg: ""), .init(cmd: "0803", arg: "1"),
    ] {
        guard case .failure(let e) = r.parsed else { Issue.record("accepted \(r)"); continue }
        #expect(e.code == .badRequest)
    }
}

@Test func wireIsOneSortedLineAndRoundTrips() {
    let status = RemoteStatus(
        connected: true, battery: 80, noise: "anc", pauseInTransparency: true, eqPreset: "Rock",
        activeScene: nil, automaticScenes: false, appVersion: "1.0")
    let response = RemoteResponse(ok: false, status: status, error: RemoteError(code: .failed, message: "a\nb"), warning: nil)
    let data = RemoteWire.encode(response)
    #expect(data.last == 0x0A)
    #expect(data.dropLast().contains(0x0A) == false)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.range(of: "\"appVersion\"")!.lowerBound < text.range(of: "\"automaticScenes\"")!.lowerBound)
    #expect(RemoteWire.decodeLine(data) == response)
    #expect(RemoteWire.decodeLine(data.dropLast()) == response)
}

@Test func decodeLineRejectsGarbageAndOversizedInput() {
    let garbage: [Data] = [Data("{".utf8), Data("[]".utf8), Data(repeating: 0x20, count: 5000)]
    for line in garbage {
        let decoded: RemoteRequest? = RemoteWire.decodeLine(line)
        #expect(decoded == nil)
    }
    let big = Data(#"{"cmd":"scene","arg":"\#(String(repeating: "x", count: 5000))"}"#.utf8)
    let decoded: RemoteRequest? = RemoteWire.decodeLine(big)
    #expect(decoded == nil)
}
