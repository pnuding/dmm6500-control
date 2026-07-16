import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var showConnection = false
    @State private var showAdvancedRate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MeasurementCardView(state: model.primary, color: AppModel.primaryColor)

            HStack(alignment: .top, spacing: 16) {
                primaryControlArea
                if model.primary.function.supportsFilter {
                    filterControl
                }
                if model.primary.function.speedControl != .none {
                    sampleRateControl
                }
            }
        }
        .padding(16)
        // No hardcoded minWidth - a fixed pixel number measured against
        // English text clips in longer locales (German labels especially)
        // and is one more thing to remember to re-measure whenever a
        // string changes. .fixedSize() instead reports this view's own
        // true intrinsic (natural) size as its min/ideal/max all at once,
        // so paired with .windowResizability(.contentSize) on the Scene
        // the window locks to exactly whatever width *this locale's*
        // rendered text actually needs - computed by AppKit's real layout
        // pass, not guessed. The trailing Spacer() that used to soak up
        // extra width in a wider-than-needed window was removed since
        // there's no longer any slack for it to fill.
        .fixedSize()
        .navigationTitle(model.windowTitle)
        .contentShape(Rectangle())
        .onTapGesture {
            // Clicking a text field is easy; clicking *away* from one to
            // release focus isn't, since clicking empty background
            // doesn't naturally resign first responder the way clicking
            // another control does.
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .onAppear {
            DispatchQueue.main.async {
                NSApp.keyWindow?.resignFirstResponderIfEditingText()
            }
        }
        .task {
            if model.host.isEmpty {
                showConnection = true
            } else {
                await model.connect()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // Matched by SwiftUI's Window(_:id:) identifier ("graph"), not
            // by title - the title is now localized, so it stops matching
            // the literal "Graph" as soon as the system locale isn't
            // English.
            guard let window = note.object as? NSWindow, window.identifier?.rawValue != "graph" else { return }
            DispatchQueue.main.async {
                window.resignFirstResponderIfEditingText()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                statusIndicator
                Button {
                    openWindow(id: "graph")
                } label: {
                    Image(systemName: "chart.xyaxis.line")
                }
                .help("Open graph window")
                .accessibilityLabel("Open graph window")
            }
        }
    }

    // ---------- range / bias / filter (plain dropdowns - no popover,
    // since a popover whose only content is itself a dropdown/toggle is a
    // pointless extra click; hidden entirely rather than just disabled
    // when the current function has no such setting) ----------

    /// Range for most functions; Diode has no adjustable range but does
    /// have its own single setting (test/bias current) in the same slot.
    /// Hidden entirely for functions with neither (Continuity/Temperature/
    /// Frequency/Period).
    @ViewBuilder
    private var primaryControlArea: some View {
        if model.primary.function == .diode {
            biasLevelControl
        } else if model.primary.function.supportsRange {
            rangeControl
        }
    }

    private var rangeControl: some View {
        Picker("Range", selection: Binding<RangeSelection>(
            get: {
                guard !model.rangeAuto else { return .auto }
                return .fixed(closestRangeOption(to: model.rangeValue)?.value ?? model.rangeValue)
            },
            set: { newValue in
                switch newValue {
                case .auto: Task { await model.setRangeAuto(true) }
                case .fixed(let v): Task { await model.setFixedRange(v) }
                }
            }
        )) {
            Text("Auto").tag(RangeSelection.auto)
            ForEach(rangeOptions) { opt in
                // The 10A current range only works on the rear AMPS
                // terminals (no remote command exists to switch to them) -
                // shown greyed out rather than hidden, so it's still
                // visible as a hint that it exists.
                Text(opt.label).tag(RangeSelection.fixed(opt.value))
                    .disabled(opt.value == 10 && (model.primary.function == .dcCurrent || model.primary.function == .acCurrent) && model.terminals != "REAR")
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(!model.connected)
        .help("Measurement range, or Auto")
    }

    private var biasLevelControl: some View {
        Picker("Bias Level", selection: Binding(
            get: { model.diodeBiasLevel },
            set: { newValue in Task { await model.setDiodeBiasLevel(newValue) } }
        )) {
            ForEach(diodeBiasOptions) { opt in Text(opt.label).tag(opt.value) }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(!model.connected)
        .help("Diode test current level")
    }

    private var filterControl: some View {
        Picker("Filter", selection: Binding(
            get: { model.filterEnabled },
            set: { newValue in Task { await model.setFilterEnabled(newValue) } }
        )) {
            Text("Off").tag(false)
            Text("Repeat 10x").tag(true)
        }
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(!model.connected)
        .help("Averaging filter: off, or repeat the instrument's default (×10)")
    }

    private enum RangeSelection: Hashable {
        case auto
        case fixed(Double)
    }

    private var rangeOptions: [RangeOption] {
        model.primary.function.fixedRangeOptions
    }

    private func closestRangeOption(to value: Double) -> RangeOption? {
        rangeOptions.min { abs($0.value - value) < abs($1.value - value) }
    }

    // ---------- sample rate: a plain native Picker for the preset (same
    // "no popover for a single control" treatment as Range/Filter), plus a
    // small separate icon button for the advanced raw-value override so
    // the common case (pick a preset) never needs an extra click, and the
    // label never has to compete for space and get truncated the way the
    // old "Sample Rate: Medium ⌄" chip did. ----------

    private var sampleRateControl: some View {
        HStack(spacing: 2) {
            Picker("Rate", selection: Binding(
                get: { model.sampleRate },
                set: { newValue in Task { await model.setSampleRate(newValue) } }
            )) {
                ForEach(SampleRatePreset.allCases) { p in Text(p.displayName).tag(p) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(!model.connected)
            .help("Measurement speed (sample rate) preset")

            Button {
                showAdvancedRate = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!model.connected)
            .help("Advanced: raw speed value")
            .accessibilityLabel("Advanced: raw speed value")
            .popover(isPresented: $showAdvancedRate) {
                advancedRateContent
                    .padding(16)
                    .frame(width: 220)
            }
        }
    }

    // The poll interval itself isn't user-editable - it's derived from
    // this speed value, since the instrument can't return a reading
    // faster than it takes to integrate/settle one (see
    // AppModel.effectivePollIntervalMs). Only ever shown when
    // model.primary.function.speedControl != .none.
    private var advancedRateContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Advanced").font(.headline)
            switch model.primary.function.speedControl {
            case .nplc, .aperture:
                // Typed LocalizedStringKey, not String: Text(_:) and
                // DecimalField's accessibilityLabel only auto-localize a
                // literal or a LocalizedStringKey-typed value - a plain
                // String variable (even built from literals via a ternary)
                // would display verbatim instead of looking up the
                // translation (see MeasurementCardView's badge() fix for
                // the same gotcha).
                let label: LocalizedStringKey = model.primary.function.speedControl == .nplc ? "NPLC" : "Aperture (s)"
                HStack(spacing: 6) {
                    Text(label).frame(width: 90, alignment: .leading)
                    DecimalField(
                        value: $model.integrationValue,
                        decimals: 4,
                        range: model.integrationRange,
                        width: 80,
                        accessibilityLabel: label,
                        onDirty: { model.integrationDirty = true },
                        onCommit: { Task { await model.applyCustomIntegration() } }
                    )
                    .disabled(model.sampleRate != .custom)
                    .overlay(dirtyOverlay(model.integrationDirty))
                    applyButton(dirty: model.integrationDirty) { Task { await model.applyCustomIntegration() } }
                }
            case .detectorBandwidth:
                HStack(spacing: 6) {
                    Text("Bandwidth").frame(width: 90, alignment: .leading)
                    Picker("Bandwidth", selection: Binding(
                        get: { model.bandwidthHz },
                        set: { newValue in Task { await model.setBandwidth(newValue) } }
                    )) {
                        ForEach(detectorBandwidthOptionsHz, id: \.self) { hz in
                            // Wrapped in String(...) so the interpolation
                            // builds a portable "%@ Hz" localization key
                            // instead of a numeric-typed format specifier.
                            Text("\(String(Int(hz))) Hz").tag(hz)
                        }
                    }
                    .help("Detector bandwidth: 3, 30, or 300 Hz")
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(model.sampleRate != .custom)
                }
            case .none:
                EmptyView()
            }
            if model.sampleRate != .custom {
                Text("Switch to Custom to edit").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // ---------- shared bits ----------

    private func applyButton(dirty: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: "checkmark").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(dirty ? Color.accentColor : Color.secondary)
        .controlSize(.small)
        .disabled(!dirty)
        .help("Apply changes")
    }

    private func dirtyOverlay(_ dirty: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.orange, lineWidth: dirty ? 2 : 0)
    }

    private var statusIndicator: some View {
        let (icon, color, label): (String, Color, LocalizedStringKey) = {
            if model.connected { return ("wifi", .green, "Connected") }
            if model.host.isEmpty { return ("wifi.slash", .secondary, "Not connected") }
            return ("wifi.exclamationmark", .orange, "Disconnected")
        }()
        return Button {
            showConnection.toggle()
        } label: {
            Image(systemName: icon)
                .foregroundStyle(color)
        }
        .popover(isPresented: $showConnection) {
            ConnectionSettingsView()
                .frame(width: 280)
                .padding()
        }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityHint(Text("Connection settings"))
    }
}
