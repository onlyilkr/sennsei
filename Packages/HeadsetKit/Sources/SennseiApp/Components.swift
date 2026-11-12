import SwiftUI

enum Palette {
    static let ground = Color(red: 0x0E / 255, green: 0x0F / 255, blue: 0x11 / 255)
    static let card = Color(red: 0x17 / 255, green: 0x19 / 255, blue: 0x1C / 255)
    static let raised = Color(red: 0x20 / 255, green: 0x23 / 255, blue: 0x27 / 255)
    static let amber = Color(red: 0xF2 / 255, green: 0xA6 / 255, blue: 0x3B / 255)
    static let textPrimary = Color(red: 0xF2 / 255, green: 0xF3 / 255, blue: 0xF4 / 255)
    static let textSecondary = Color(red: 0xA9 / 255, green: 0xAE / 255, blue: 0xB5 / 255)   // >= 7:1 on the cards
    static let error = Color(red: 0xFF / 255, green: 0x8A / 255, blue: 0x80 / 255)
    static let onAmber = Color(red: 0x0E / 255, green: 0x0F / 255, blue: 0x11 / 255)
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A selectable pill used by the noise control and the preset grid.
struct ChoiceButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 28)
                .foregroundStyle(selected ? Palette.onAmber : Palette.textPrimary)
                .background(selected ? Palette.amber : Palette.raised, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A scene box: title and a one-line summary; the selected one has an amber outline.
struct SceneButton: View {
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .minimumScaleFactor(0.8)
            .foregroundStyle(Palette.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 4)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Palette.amber : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct FooterButton: View {
    let title: String
    let systemImage: String
    var compact = false   // icon only (the title stays as accessibility label and tooltip)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(FooterLabelStyle(compact: compact))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 28)
                .foregroundStyle(Palette.textPrimary)
                .background(Palette.raised, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct FooterLabelStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon
        } else {
            HStack(spacing: 4) { configuration.icon; configuration.title }
        }
    }
}
