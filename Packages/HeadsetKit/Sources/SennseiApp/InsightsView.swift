import AppKit
import Charts
import HeadsetCore
import SennseiCore
import SwiftUI
import UniformTypeIdentifiers

/// What the Insights window needs: the same service and store the app records into.
struct InsightsContext: Sendable {
    let service: InsightsService
    let store: InsightsStore
    /// True when per-app audio activity is unavailable (below macOS 14.2).
    let unsupported: Bool
    /// SENNSEI_DEMO=1: shows the empty state and never reads the real store or settings.
    let demo: Bool
}

private enum Series {
    case listening, call
    var key: String { self == .listening ? "insights.listening" : "insights.calls" }
}

private let callColor = Color(red: 0x6F / 255, green: 0xA8 / 255, blue: 0xFF / 255)

/// The Insights window. All numbers come from `InsightsViewState`; this view only draws them.
struct InsightsView: View {
    let context: InsightsContext
    @State private var range: InsightsRange = .week
    @State private var state: InsightsViewState?
    @State private var loader = LatestLoader<InsightsViewState>()
    @State private var confirmDelete = false
    @State private var deleteFailed = false
    @State private var exportFailed = false
    /// Screenshot rendering only: a fixed state that is shown as is (no store, no reloads, no scrolling).
    private let previewState: InsightsViewState?

    init(context: InsightsContext, previewState: InsightsViewState? = nil) {
        self.context = context
        self.previewState = previewState
        _state = State(initialValue: previewState)
    }

    private var service: InsightsService { context.service }
    private var locale: Locale { .current }
    private func text(_ key: String) -> String { Strings.text(key, locale: locale) }
    private func duration(_ seconds: TimeInterval) -> String { InsightsViewState.formatDuration(seconds, locale: locale) }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let state {
                ForEach(Array(state.notes.enumerated()), id: \.offset) { noteView($0.element.text, warning: $0.element.isWarning) }
                totals(state)
                if !state.apps.isEmpty { appsCard(state) }
                if !state.noise.isEmpty { noiseCard(state) }
                if state.days.contains(where: { $0.listening > 0 || $0.call > 0 }) { dailyCard(state) }
                if !state.battery.isEmpty { batteryCard(state) }
            }
            dataControls
        }
        .padding(16)
    }

    var body: some View {
        Group {
            if previewState == nil { ScrollView { content } } else { content }
        }
        .frame(
            minWidth: previewState == nil ? 460 : nil, idealWidth: previewState == nil ? 520 : nil,
            minHeight: previewState == nil ? 520 : nil, idealHeight: previewState == nil ? 680 : nil)
        .background(Palette.ground)
        .preferredColorScheme(.dark)
        .task(id: range) {
            while !Task.isCancelled {
                reload()
                try? await Pause.sleep(.seconds(10))
            }
        }
        .onDisappear { loader.cancel() }
        .onChange(of: context.demo ? false : service.isRecording) { reload() }
        .confirmationDialog(text("insights.deleteConfirm"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(text("insights.deleteHistory"), role: .destructive) {
                Task {
                    let ok = await service.deleteHistory()
                    deleteFailed = !ok
                    reload()
                }
            }
            Button(text("insights.cancel"), role: .cancel) {}
        }
    }

    /// Starts a load that replaces any load still in flight; only the newest result is applied.
    private func reload() {
        guard previewState == nil else { return }
        let context = context, range = range, locale = locale
        loader.load(produce: {
            if context.demo { return InsightsViewState.demo(range: range, now: Date(), calendar: .current, locale: locale) }
            return await InsightsViewState.make(
                range: range, store: context.store, service: context.service, now: Date(), calendar: .current,
                locale: locale, unsupported: context.unsupported)
        }, apply: { state = $0 })
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Text(text("insights.title"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if previewState != nil {
                // ImageRenderer cannot draw the native segmented control: a look-alike for screenshots.
                HStack(spacing: 2) {
                    ForEach(InsightsRange.allCases, id: \.self) { item in
                        Text(text(item.titleKey))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 22)
                            .background(item == range ? Palette.raised : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(item == range ? Color.white.opacity(0.18) : .clear))
                    }
                }
                .padding(2)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 7))
                .frame(width: 240)
            } else {
                Picker(text("insights.title"), selection: $range) {
                    ForEach(InsightsRange.allCases, id: \.self) { Text(text($0.titleKey)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }
        }
    }

    private func noteView(_ note: String, warning: Bool) -> some View {
        Text(note)
            .font(.system(size: 12))
            .foregroundStyle(warning ? Palette.error : Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func totals(_ state: InsightsViewState) -> some View {
        HStack(spacing: 10) {
            bigNumber(text("insights.listening"), duration(state.totals.listening), tint: Palette.amber)
            bigNumber(text("insights.calls"), duration(state.totals.call), tint: callColor)
        }
    }

    private func bigNumber(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(Palette.textSecondary)
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func appsCard(_ state: InsightsViewState) -> some View {
        Card(title: text("insights.perApp")) {
            let unit = text("insights.unit.minute"), kind = text("insights.title")
            Chart {
                ForEach(state.apps) { app in
                    BarMark(x: .value(unit, app.listening / 60), y: .value(text("insights.perApp"), app.name))
                        .foregroundStyle(by: .value(kind, text(Series.listening.key)))
                        .position(by: .value(kind, text(Series.listening.key)))
                    if app.call > 0 {
                        BarMark(x: .value(unit, app.call / 60), y: .value(text("insights.perApp"), app.name))
                            .foregroundStyle(by: .value(kind, text(Series.call.key)))
                            .position(by: .value(kind, text(Series.call.key)))
                    }
                }
            }
            .chartForegroundStyleScale([text(Series.listening.key): Palette.amber, text(Series.call.key): callColor])
            .chartXAxisLabel(unit)
            .frame(height: CGFloat(max(1, state.apps.count)) * 44 + 40)
            VStack(spacing: 6) {
                ForEach(state.apps) { app in
                    HStack(spacing: 8) {
                        Text(app.name).font(.system(size: 12)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                        Spacer()
                        Text("\(text("insights.listening")) \(duration(app.listening))  ·  \(text("insights.calls")) \(duration(app.call))")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .accessibilityLabel("\(text("insights.listening")) \(duration(app.listening)), \(text("insights.calls")) \(duration(app.call))")
                        if !app.isOther {
                            Button { service.addExcluded(app.id) } label: { Image(systemName: "eye.slash") }
                                .buttonStyle(.plain)
                                .foregroundStyle(Palette.textSecondary)
                                .help(text("insights.exclude"))
                                .accessibilityLabel(text("insights.exclude") + " " + app.name)
                                .disabled(service.excludedApps.contains(app.id))
                        }
                    }
                }
            }
        }
    }

    private func noiseCard(_ state: InsightsViewState) -> some View {
        Card(title: text("insights.noiseShare")) {
            HStack(spacing: 16) {
                Chart(state.noise) { row in
                    SectorMark(angle: .value("s", row.seconds), innerRadius: .ratio(0.62), angularInset: 1.5)
                        .foregroundStyle(noiseColor(row.mode))
                }
                .frame(width: 110, height: 110)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.noise) { row in
                        HStack(spacing: 8) {
                            Circle().fill(noiseColor(row.mode)).frame(width: 8, height: 8)
                            Text(text(Self.noiseKey(row.mode))).font(.system(size: 12)).foregroundStyle(Palette.textPrimary)
                            Spacer()
                            Text("\(row.percent)%").font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private func dailyCard(_ state: InsightsViewState) -> some View {
        let kind = text("insights.title")
        let listening = state.days.reduce(0) { $0 + $1.listening }, call = state.days.reduce(0) { $0 + $1.call }
        return Card(title: text("insights.dailyHours")) {
            Chart {
                ForEach(state.days) { day in
                    BarMark(x: .value(text("insights.day"), day.day, unit: .day), y: .value(text("insights.dailyHours"), day.listening / 3600))
                        .foregroundStyle(by: .value(kind, text(Series.listening.key)))
                        .position(by: .value(kind, text(Series.listening.key)))
                    BarMark(x: .value(text("insights.day"), day.day, unit: .day), y: .value(text("insights.dailyHours"), day.call / 3600))
                        .foregroundStyle(by: .value(kind, text(Series.call.key)))
                        .position(by: .value(kind, text(Series.call.key)))
                }
            }
            .chartForegroundStyleScale([text(Series.listening.key): Palette.amber, text(Series.call.key): callColor])
            .frame(height: 150)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text("insights.dailyHours"))
            .accessibilityValue(String(
                format: text("insights.a11y.daily"), duration(listening), duration(call), state.days.count))
        }
    }

    private func batteryCard(_ state: InsightsViewState) -> some View {
        Card(title: text("insights.battery")) {
            Chart(state.battery) { point in
                LineMark(x: .value(text("insights.time"), point.time), y: .value(text("insights.battery"), point.percent))
                    .foregroundStyle(Palette.amber)
                    .interpolationMethod(.stepEnd)
            }
            .chartYScale(domain: 0...100)
            .frame(height: 120)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text("insights.battery"))
            .accessibilityValue(batterySummary(state.battery))
        }
    }

    private func batterySummary(_ points: [InsightsViewState.BatteryPoint]) -> String {
        guard let last = points.last, let low = points.map(\.percent).min(), let high = points.map(\.percent).max() else { return "" }
        return String(format: text("insights.a11y.battery"), last.percent, low, high)
    }

    @ViewBuilder private var dataControls: some View {
        if context.demo {
            Card(title: text("insights.recording")) {
                Text(text("insights.recording.hint"))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            liveControls
        }
    }

    private var liveControls: some View {
        Card(title: text("insights.recording")) {
            Toggle(text("insights.recording.toggle"), isOn: Binding(get: { service.isRecording }, set: { service.setRecording($0) }))
                .toggleStyle(.switch)
                .tint(Palette.amber)
                .font(.system(size: 12))
                .foregroundStyle(Palette.textPrimary)
            Text(text("insights.recording.hint"))
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !service.excludedApps.isEmpty {
                Text(text("insights.excluded"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                ForEach(service.excludedApps, id: \.self) { id in
                    HStack {
                        Text(id).font(.system(size: 12)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                        Spacer()
                        Button { service.removeExcluded(id) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain)
                            .foregroundStyle(Palette.textSecondary)
                            .accessibilityLabel(text("insights.remove") + " " + id)
                    }
                }
            }
            HStack(spacing: 8) {
                Button(text("insights.export")) { Task { await exportCSV() } }
                Button(text("insights.deleteHistory"), role: .destructive) { confirmDelete = true }
            }
            if deleteFailed || service.deleteFailed { noteLine(text("insights.deleteFailed")) }
            if exportFailed { noteLine(text("insights.exportFailed")) }
        }
    }

    private func noteLine(_ message: String) -> some View {
        Text(message).font(.system(size: 11)).foregroundStyle(Palette.error)
    }

    // MARK: Actions

    /// User-initiated; the file contains only what `InsightsStore.exportCSV()` returns.
    private func exportCSV() async {
        exportFailed = false
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "sennsei-insights.csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let csv = try await context.store.exportCSV()
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Sennsei insights: export failed: \(error)")
            exportFailed = true
        }
    }

    private func noiseColor(_ mode: NoiseMode) -> Color {
        switch mode {
        case .anc: Palette.amber
        case .transparency: callColor
        case .off: Palette.textSecondary
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
