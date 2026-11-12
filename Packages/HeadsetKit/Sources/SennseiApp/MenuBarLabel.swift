import AppKit
import SennseiCore
import SwiftUI

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let state = MenuBarLabelState(model: model)
        let symbolName = state.connected ? "headphones" : "headphones.slash"
        let text = state.batteryPercent.map { "\($0)%" }
        // The symbol and the digits are drawn into ONE template image so their vertical alignment is
        // controlled here: the status item places an Image and a Text on slightly different baselines
        // (the headphones' ear cups hang below the digits' baseline), and a symbol inlined in a Text is
        // dropped by the menu bar.
        Image(nsImage: MenuBarGlyph.image(symbolName: symbolName, text: text))
            .accessibilityLabel(AppInfo.name)
            .accessibilityValue(text ?? "")
    }
}

enum MenuBarGlyph {
    static let height: CGFloat = 18
    static let fontSize: CGFloat = 13
    static let spacing: CGFloat = 3
    /// Visual nudge (points, positive = up) applied to the symbol so the ear cups line up with the digits.
    static let symbolNudge: CGFloat = -0.5

    static func image(symbolName: String, text: String?) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        let config = NSImage.SymbolConfiguration(pointSize: fontSize, weight: .regular)
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        let symbolSize = symbol?.size ?? .zero
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = text.map { ($0 as NSString).size(withAttributes: attributes) } ?? .zero
        let gap: CGFloat = (symbol != nil && text != nil) ? spacing : 0
        let width = ceil(symbolSize.width + gap + textSize.width)

        let image = NSImage(size: NSSize(width: max(width, 1), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            if let symbol {
                let y = (height - symbolSize.height) / 2 + symbolNudge
                symbol.draw(in: NSRect(x: x, y: y, width: symbolSize.width, height: symbolSize.height))
                x += symbolSize.width + gap
            }
            if let text {
                // Centre the digits (cap height) vertically. `draw(at:)` takes the bottom of the line box,
                // which lies `-descender` below the baseline.
                let baseline = (height - font.capHeight) / 2
                (text as NSString).draw(at: NSPoint(x: x, y: baseline + font.descender), withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
