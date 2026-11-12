import HeadsetBluetooth
import HeadsetCore
import HeadsetSimulator
import SennseiControl
import SennseiCore
import SwiftUI
import os

@main
struct SennseiApp: App {
    @State private var model: AppModel
    private let controlServer: ControlServer
    private let hotkeys: HotkeyCenter
    private let insights: InsightsService
    @NSApplicationDelegateAdaptor(QuitDelegate.self) private var quitDelegate
    private let insightsContext: InsightsContext

    init() {
        // Before anything that touches the real app, the headset, sockets or settings; does not return when set.
        PreviewRenderer.runIfRequested()
        let model = AppModel(
            makeTransport: makeTransport,
            sceneStore: SceneStore(url: SceneStore.defaultURL()),
            frontAppMonitor: WorkspaceFrontAppMonitor())
        _model = State(initialValue: model)
        IntentModelProvider.model = model   // init runs on the main actor; App Intents read it from there
        // Started here, not in a view: the MenuBarExtra content is only created on first open,
        // and the battery must show in the menu bar before that.
        Task { await model.start() }

        // The remote-control socket is optional: if it cannot start the app keeps running and
        // only the command-line client is unavailable.
        let socketURL = ControlPaths.defaultSocketURL()
        let server = ControlServer(socketURL: socketURL) { command in await model.run(command) }
        do {
            try ControlPaths.preparePrivateDirectory(socketURL.deletingLastPathComponent())
            try server.start()
        } catch {
            NSLog("Sennsei: control socket unavailable: \(error)")
        }
        controlServer = server
        hotkeys = HotkeyCenter(model: model)

        // Insights only reads (CoreAudio process state and the model's snapshot); it never writes to the
        // headphones. The demo headset has no real audio route, so the service is not started there.
        let insightsStore = InsightsStore(url: InsightsStore.defaultURL())
        let insights = InsightsService(
            store: insightsStore,
            source: makeAudioActivitySource(),
            headset: { model.insightsSnapshot() })
        if ProcessInfo.processInfo.environment["SENNSEI_DEMO"] != "1" { insights.start() }
        self.insights = insights
        self.insightsContext = InsightsContext(
            service: insights, store: insightsStore, unsupported: !audioActivityAvailable(),
            demo: ProcessInfo.processInfo.environment["SENNSEI_DEMO"] == "1")
        // Quit (Quit button, Dock, Cmd+Q: all end in NSApp.terminate) goes through the delegate's
        // applicationShouldTerminate, which waits (bounded) for the Insights flush before the process exits.
        QuitDelegate.coordinator = QuitCoordinator(
            insights: insights, stopControl: { server.stop() }, stopModel: { await model.stop() })
    }

    var body: some SwiftUI.Scene {
        MenuBarExtra {
            MenuPanel(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window(Strings.text("hotkey.title", locale: .current), id: "shortcuts") {
            ShortcutsWindow(model: model)
        }
        .windowResizability(.contentSize)

        // A plain Window scene does not open at launch; the panel opens it with openWindow(id: "insights").
        Window(Strings.text("insights.title", locale: .current), id: "insights") {
            InsightsView(context: insightsContext)
        }
    }
}

/// `SENNSEI_DEMO=1` uses the simulated headset; otherwise the real RFCOMM link.
/// `AppModel.start()` runs on the main actor and is the only caller, so this nonisolated factory
/// can assume main-actor isolation to build the `@MainActor` `RFCOMMTransport`.
private func makeTransport() -> any HeadsetTransport {
    let environment = ProcessInfo.processInfo.environment
    if environment["SENNSEI_DEMO"] == "1" { return SimulatedHeadset() }
    let name = environment["SENNSEI_DEVICE_NAME"] ?? "ACCENTUM"
    return MainActor.assumeIsolated { RFCOMMTransport(deviceName: name) }
}

/// CoreAudio per-process activity needs macOS 14.2; below that Insights records only noise mode and battery.
private func audioActivityAvailable() -> Bool {
    if #available(macOS 14.2, *) { return true }
    return false
}

private func makeAudioActivitySource() -> any AudioActivitySource {
    if #available(macOS 14.2, *) {
        let name = ProcessInfo.processInfo.environment["SENNSEI_DEVICE_NAME"] ?? "ACCENTUM"
        return CoreAudioActivitySource(headphoneName: name)
    }
    return UnavailableAudioActivitySource()
}

/// Defers termination until the Insights flush has been written (at most the coordinator's timeout).
final class QuitDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var coordinator: QuitCoordinator?

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator = Self.coordinator else {
            Logger(subsystem: AppInfo.bundleIdentifier, category: "quit")
                .error("quit hook missing: terminating without flushing insights")
            return .terminateNow
        }
        // begin's Bool is intentionally ignored: a repeated quit request just answers .terminateLater again.
        coordinator.begin { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
