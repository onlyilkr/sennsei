import AppKit
import HeadsetCore
import SennseiCore
import SwiftUI

struct MenuPanel: View {
    let model: AppModel
    /// Screenshot rendering only: `ImageRenderer` cannot draw the native switch (an AppKit view), so the preview
    /// draws a look-alike. Always false in the app.
    var drawnSwitches = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let locale = Locale.current
        let panel = PanelViewState(model: model, locale: locale)
        VStack(spacing: 10) {
            header(panel)
            Card(title: Strings.text("noise.title", locale: locale)) { noiseControl(panel, locale: locale) }
            Card(title: Strings.text("scene.title", locale: locale)) { scenesRow(panel, locale: locale) }
            Card(title: Strings.text("eq.title", locale: locale)) { equalizer(panel, locale: locale) }
            if let error = panel.errorText {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer(panel, locale: locale)
        }
        .padding(12)
        .frame(width: 320)
        .background(Palette.ground)
        .preferredColorScheme(.dark)
    }

    private func header(_ panel: PanelViewState) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(panel.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.textPrimary)
                Text(panel.subtitle).font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            if let battery = panel.batteryText {
                Label(battery, systemImage: "battery.75percent")
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Palette.amber)
                    .accessibilityLabel("\(Strings.text("status.battery", locale: .current)) \(battery)")
            }
        }
        .padding(.horizontal, 4)
    }

    private func noiseControl(_ panel: PanelViewState, locale: Locale) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(NoiseMode.allCases, id: \.self) { mode in
                    ChoiceButton(title: Strings.text(Self.noiseKey(mode), locale: locale), selected: panel.noiseSelection == mode) {
                        Task { await model.setNoiseMode(mode) }
                    }
                }
            }
            .disabled(!panel.noiseEnabled)
            if drawnSwitches {
                DrawnSwitchRow(title: Strings.text("noise.pauseInTransparency", locale: locale), isOn: panel.pauseInTransparency ?? false)
            } else {
                Toggle(
                    Strings.text("noise.pauseInTransparency", locale: locale),
                    isOn: Binding(
                        get: { panel.pauseInTransparency ?? false },
                        set: { value in Task { await model.setPauseInTransparency(value) } })
                )
                .toggleStyle(.switch)
                .tint(Palette.amber)
                .font(.system(size: 12))
                .foregroundStyle(Palette.textPrimary)
                .disabled(!panel.pauseEnabled)
            }
        }
    }

    private func equalizer(_ panel: PanelViewState, locale: Locale) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(panel.presets, id: \.self) { name in
                    ChoiceButton(title: Strings.text("eq.preset.\(name)", locale: locale), selected: panel.selectedPreset == name) {
                        Task { await model.applyPreset(name) }
                    }
                }
            }
            .disabled(!panel.eqEnabled)
            if let note = panel.eqNote {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func scenesRow(_ panel: PanelViewState, locale: Locale) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(panel.scenes) { scene in
                    SceneButton(title: scene.title, subtitle: scene.subtitle, selected: scene.selected) {
                        Task { await model.applyScene(scene.id) }
                    }
                    .disabled(!scene.enabled)
                }
            }
            if drawnSwitches {
                DrawnSwitchRow(title: Strings.text("scene.automatic", locale: locale), isOn: panel.automaticScenes)
            } else {
                Toggle(
                    Strings.text("scene.automatic", locale: locale),
                    isOn: Binding(
                        get: { panel.automaticScenes },
                        set: { model.setAutomaticScenes($0) })
                )
                .toggleStyle(.switch)
                .tint(Palette.amber)
                .font(.system(size: 12))
                .foregroundStyle(Palette.textPrimary)
                .disabled(!panel.automaticScenesEnabled)
            }
            Text(Strings.text("scene.automatic.hint", locale: locale))
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let note = panel.sceneNote {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func footer(_ panel: PanelViewState, locale: Locale) -> some View {
        // Four labelled buttons do not fit 320 pt (Turkish labels are longer); then show icons only.
        let compact = panel.showReconnect
        return HStack(spacing: 6) {
            if panel.showReconnect {
                FooterButton(title: Strings.text("action.reconnect", locale: locale), systemImage: "arrow.clockwise", compact: compact) {
                    Task { await model.reconnect() }
                }
            }
            FooterButton(title: Strings.text("panel.shortcuts", locale: locale), systemImage: "keyboard", compact: compact) {
                openWindow(id: "shortcuts")
                NSApp.activate()
            }
            FooterButton(title: Strings.text("panel.insights", locale: locale), systemImage: "chart.bar", compact: compact) {
                openWindow(id: "insights")
                NSApp.activate()
            }
            FooterButton(title: Strings.text("action.quit", locale: locale), systemImage: "power", compact: compact) {
                // Synchronous on purpose: terminate inside a MainActor Task deadlocks with .terminateLater
                // (see QuitCoordinator). The headset is disconnected by the coordinator.
                NSApplication.shared.terminate(nil)
            }
            .disabled(!panel.quitEnabled)
        }
    }

    private static func noiseKey(_ mode: NoiseMode) -> String {
        switch mode {
        case .anc: "noise.anc"
        case .transparency: "noise.transparency"
        case .off: "noise.off"
        }
    }
}

/// A static switch row for screenshots only (see `MenuPanel.drawnSwitches`).
struct DrawnSwitchRow: View {
    let title: String
    let isOn: Bool

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(Palette.textPrimary)
            Spacer()
            Capsule()
                .fill(isOn ? Palette.amber : Palette.raised)
                .overlay(Capsule().strokeBorder(Color.white.opacity(isOn ? 0 : 0.12), lineWidth: 1))
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(Color.white).frame(width: 18, height: 18).padding(2).shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                }
                .frame(width: 38, height: 22)
        }
    }
}
