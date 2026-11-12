import KeyboardShortcuts
import SennseiCore
import SwiftUI

/// The small window with one recorder per action. Opened from the panel's "Shortcuts…" row.
struct ShortcutsWindow: View {
    let model: AppModel
    /// Screenshot rendering only: shortcut labels (keyed by the action's `nameKey`) drawn in place of the
    /// recorder controls, which are AppKit views that `ImageRenderer` cannot draw.
    var previewLabels: [String: String]?

    var body: some View {
        let locale = Locale.current
        VStack(alignment: .leading, spacing: 12) {
            Text(Strings.text("hotkey.title", locale: locale))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 8) {
                row(.cycleNoise, locale: locale)
                row(.nextEQ, locale: locale)
                ForEach(model.scenes) { scene in
                    row(.scene(scene.id), locale: locale)
                }
            }
            .padding(12)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
            Text(Strings.text("hotkey.hint", locale: locale))
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360)
        .background(Palette.ground)
        .preferredColorScheme(.dark)
    }

    private func row(_ action: HotkeyAction, locale: Locale) -> some View {
        let title = action.displayName(scenes: model.scenes, locale: locale)
        return HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            if let labels = previewLabels {
                Text(labels[action.nameKey] ?? "")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 96, height: 24)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 6))
            } else {
                KeyboardShortcuts.Recorder(for: HotkeyCenter.name(for: action))
                    .accessibilityLabel(title)
            }
        }
    }
}
