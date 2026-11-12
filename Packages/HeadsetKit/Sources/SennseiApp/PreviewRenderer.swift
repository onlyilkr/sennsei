import AppKit
import HeadsetSimulator
import ImageIO
import SennseiCore
import SwiftUI
import UniformTypeIdentifiers

/// `SennseiApp --render-previews <dir>`: draws the panel, the Insights window and the Shortcuts window with
/// invented sample data into PNG files for the README, then exits. It runs at the very start of `SennseiApp.init`,
/// before the real model, the Insights service, the control socket, the hotkeys or Bluetooth exist, and it uses
/// only the in-memory `SimulatedHeadset` and `PreviewSamples`: no Bluetooth, no CoreAudio, no sockets, no network,
/// nothing from the real app's settings or Application Support folder.
@MainActor
enum PreviewRenderer {
    static let flag = "--render-previews"

    /// Returns normally when the flag is absent; otherwise renders and never returns.
    static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard let index = arguments.firstIndex(of: flag) else { return }
        guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("-") else {
            fputs("usage: SennseiApp \(flag) <output directory>\n", stderr)
            exit(2)
        }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        // Safety net: this must finish by itself within seconds.
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
            fputs("render-previews: timed out\n", stderr)
            exit(1)
        }
        Task { @MainActor in
            do {
                try await render(to: directory)
                exit(0)
            } catch {
                fputs("render-previews: \(error)\n", stderr)
                exit(1)
            }
        }
        // init cannot await: keep the main run loop turning so the Task above runs; it ends the process.
        while true { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2)) }
    }

    enum RenderError: Error { case render(String), language(String) }

    private static func render(to directory: URL) async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard Locale.current.language.languageCode?.identifier == "en" else {
            throw RenderError.language("run with: -AppleLanguages \"(en)\" -AppleLocale en_US (got \(Locale.current.identifier))")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // A throwaway settings domain, so nothing is read from or written to the real app's preferences.
        let suite = "sennsei.render-previews.\(UUID().uuidString)"
        let settings = UserDefaults(suiteName: suite)!
        defer { settings.removePersistentDomain(forName: suite) }

        var simulated = SimulatedState.accentumProbed
        simulated.battery = UInt8(PreviewSamples.batteryPercent)
        let state = simulated
        let model = AppModel(
            makeTransport: { SimulatedHeadset(state: state) }, sceneStore: nil, frontAppMonitor: nil, settings: settings)
        await model.start()
        await model.applyScene(PreviewSamples.activeSceneID)
        guard model.phase == .connected else { throw RenderError.render("simulated headset did not connect") }

        let panel = MenuPanel(model: model, drawnSwitches: true)
        let calendar = Calendar.current
        let insightsState = PreviewSamples.insightsState(calendar: calendar, locale: .current)
        let insights = InsightsView(context: sampleInsightsContext(settings: settings), previewState: insightsState)
        let shortcuts = ShortcutsWindow(model: model, previewLabels: PreviewSamples.shortcutLabels)

        try write(window(panel, cornerRadius: 14), named: "panel.png", in: directory)
        try write(window(insights.frame(width: 520), cornerRadius: 14), named: "insights.png", in: directory)
        try write(window(shortcuts, cornerRadius: 14), named: "shortcuts.png", in: directory)
        let hero = HeroImage(panel: panel, insights: insights.frame(width: 520))
        try write(hero, named: "hero.png", in: directory, scale: 2, opaque: true)
        try write(hero, named: "social-preview.png", in: directory, scale: 0.8, opaque: true)
    }

    /// A context that is never used to read anything: the view is given its state directly.
    private static func sampleInsightsContext(settings: UserDefaults) -> InsightsContext {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sennsei-render-previews-unused/insights.sqlite")
        let store = InsightsStore(url: url)
        let service = InsightsService(
            store: store, source: UnavailableAudioActivitySource(),
            headset: { HeadsetInsightsSnapshot(connected: false, noiseMode: nil, battery: nil, charging: nil) },
            settings: settings)
        return InsightsContext(service: service, store: store, unsupported: false, demo: true)
    }

    /// The content as a rounded window with a soft shadow on a transparent margin.
    private static func window<V: View>(_ content: V, cornerRadius: CGFloat) -> some View {
        content
            .environment(\.colorScheme, .dark)
            .fixedSize()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
            .padding(28)
    }

    private static func write<V: View>(_ view: V, named name: String, in directory: URL, scale: CGFloat = 2, opaque: Bool = false) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.cgImage else { throw RenderError.render("\(name): no image") }
        try PNGWriter.write(image, to: directory.appendingPathComponent(name), opaque: opaque)
    }
}

/// The repository's hero image (1600x800 points; README at 2x, GitHub social preview at 0.8x): mark, name,
/// tagline and feature lines on the left, the Insights window (top part) behind and the panel in front.
private struct HeroImage<Panel: View, Insights: View>: View {
    let panel: Panel
    let insights: Insights

    private let graphite = Color(red: 0x0E / 255, green: 0x0F / 255, blue: 0x11 / 255)

    var body: some View {
        ZStack(alignment: .topLeading) {
            graphite
            RadialGradient(
                colors: [Palette.amber.opacity(0.20), .clear], center: UnitPoint(x: 0.74, y: 0.5),
                startRadius: 10, endRadius: 640)
            VStack(alignment: .leading, spacing: 20) {
                AppMark(size: 120)
                Text("Sennsei")
                    .font(.system(size: 78, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.textPrimary)
                Text("Headphone control,\nright in the menu bar.")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(Palette.textSecondary)
                    .lineSpacing(3)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(["Noise control · Equalizer · Scenes", "CLI · Shortcuts · Hotkeys", "Local listening stats"], id: \.self) { line in
                        Text(line)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Palette.textPrimary)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Color.white.opacity(0.07), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10)))
                    }
                }
                .padding(.top, 4)
            }
            .padding(.leading, 80)
            .padding(.top, 96)

            // Insights: only the top part (header, totals, by-app chart, noise share), behind the panel.
            insights
                .fixedSize()
                .frame(width: 520, height: 755, alignment: .top)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 22, y: 10)
                .scaleEffect(0.94, anchor: .topLeading)
                .offset(x: 987, y: 44)
            panel
                .fixedSize()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 28, y: 14)
                .scaleEffect(1.06, anchor: .topLeading)
                .offset(x: 668, y: 236)
        }
        .frame(width: 1600, height: 800, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .dark)
    }
}

/// The app mark in SwiftUI (same colours as the icon): graphite rounded square with the amber headphones.
private struct AppMark: View {
    let size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
            .fill(Color(red: 0x16 / 255, green: 0x18 / 255, blue: 0x1B / 255))
            .overlay(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1.5))
            .overlay(
                Image(systemName: "headphones")
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(Palette.amber))
            .frame(width: size, height: size)
    }
}

/// Writes a PNG with no metadata beyond the standard sRGB profile.
enum PNGWriter {
    /// `opaque` drops the alpha channel (smaller file) for images that fill their whole canvas.
    static func write(_ image: CGImage, to url: URL, opaque: Bool = false) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue) else { throw PreviewRenderer.RenderError.render("bitmap context") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flat = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw PreviewRenderer.RenderError.render("png destination") }
        CGImageDestinationAddImage(destination, flat, nil)
        guard CGImageDestinationFinalize(destination) else { throw PreviewRenderer.RenderError.render("png write") }
    }
}
