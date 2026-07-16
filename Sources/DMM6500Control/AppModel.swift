import SwiftUI
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let device = DeviceClient()

    @Published var host: String
    @Published var connected = false
    @Published var connectionError: String? = nil

    private static let hostDefaultsKey = "deviceHost"

    // Populated from *IDN? right after connecting.
    @Published var deviceModel: String = ""
    @Published var firmwareVersion: String = ""
    @Published var windowTitle: String = String(localized: "DMM6500 Control")

    @Published var primary: MeasurementState

    // ---------- sample rate ----------

    @Published var sampleRate: SampleRatePreset = .medium
    // NPLC count, used only when the primary function's speedControl is
    // .nplc. Shown (and, only under .custom, editable) in the Advanced
    // disclosure; kept in sync with the active preset's own value
    // otherwise, so the field always reflects what's in effect on the
    // device.
    @Published var integrationValue: Double = 1
    @Published var integrationDirty = false
    // Detector bandwidth in Hz, used only when speedControl is
    // .detectorBandwidth - a discrete choice (3/30/300 Hz on this
    // instrument), not a freely-typed value, so it's applied immediately
    // on selection rather than going through a dirty/apply flow.
    @Published var bandwidthHz: Double = 30

    // NPLC and Aperture (Frequency/Period) share the `integrationValue`
    // field above but have different valid ranges.
    var integrationRange: ClosedRange<Double> {
        switch primary.function.speedControl {
        case .aperture: return 0.002...0.273
        default: return 0.0005...12
        }
    }

    // There's no separate user-facing poll-interval control: the
    // instrument can't return a reading faster than it takes to
    // integrate/settle one, so the poll interval is derived directly from
    // whichever speed value is currently in effect, plus a fixed margin
    // for SCPI round-trip overhead.
    var effectivePollIntervalMs: Int {
        let overheadMs = 40.0
        let integrationSeconds: Double
        switch primary.function.speedControl {
        case .nplc:
            let nplc = sampleRate == .custom ? integrationValue : (sampleRate.speedValue(for: .nplc) ?? integrationValue)
            // Approximate 1 PLC ≈ 16.7ms (60Hz line) - slightly optimistic
            // at 50Hz (20ms), but the overhead margin below covers it.
            integrationSeconds = nplc / 60.0
        case .detectorBandwidth:
            let hz = sampleRate == .custom ? bandwidthHz : (sampleRate.speedValue(for: .detectorBandwidth) ?? bandwidthHz)
            // A detector bandwidth is a low-frequency filter cutoff, not
            // directly a settling time - approximated here as its
            // reciprocal (e.g. 3 Hz -> ~333ms), which is the right order
            // of magnitude for how long the filter needs to settle.
            integrationSeconds = 1.0 / max(hz, 1)
        case .aperture:
            // Aperture already IS an integration time in seconds - no
            // conversion needed, unlike NPLC (power line cycles) or
            // detector bandwidth (a filter cutoff frequency).
            integrationSeconds = sampleRate == .custom ? integrationValue : (sampleRate.speedValue(for: .aperture) ?? integrationValue)
        case .none:
            // No adjustable speed control - fall back to a nominal
            // conversion time rather than hammering the instrument as
            // fast as the network allows.
            integrationSeconds = 0.1
        }
        return max(50, Int((integrationSeconds * 1000.0 + overheadMs).rounded()))
    }

    // ---------- range / filter ----------

    @Published var rangeAuto: Bool = true
    @Published var rangeValue: Double = 0

    // Simplified per the user's own read on this: in practice the filter
    // is either off, or on with the instrument's own defaults (Repeating,
    // count 10) - not worth a separate type/count picker.
    @Published var filterEnabled = false

    // Diode's forward-voltage-drop test current - the only per-function
    // config this app exposes that isn't range/filter/speed, so it lives
    // here rather than warranting its own section.
    @Published var diodeBiasLevel: Double = 0.001

    // ---------- read-only status badges (display only, no editing UI) ----------

    // "FRON"/"REAR" - which input terminals are physically selected. This
    // is a single global hardware switch (not per-function), fetched
    // regardless of the active function; gates whether the 10A current
    // range is actually usable (rear AMPS jack only).
    @Published var terminals: String = "FRON"
    // nil = not applicable for the current function (see
    // DMMFunction.supportsAutoZero - confirmed against real hardware,
    // sending AZERo? to an unsupported function visibly errors on the
    // instrument itself, not just something to silently ignore on our
    // side). inputImpedanceAuto is nil for every function except DC
    // Voltage, which is the only one the manual documents it for.
    @Published var autoZeroEnabled: Bool?
    @Published var inputImpedanceAuto: Bool?

    @Published var graphing = false
    @Published var graphSeries: GraphSeries?
    var graphStartTime = Date()
    // Data is recorded at full poll rate, but the UI notification for it
    // is coalesced (see recordSample) - this tracks the last time one
    // actually went out.
    var lastGraphPublish = Date.distantPast

    private var pollTask: Task<Void, Never>?
    private var configPollTask: Task<Void, Never>?
    // What the device currently has selected via SENSe:FUNCtion, so the
    // poll loop can use the cheaper READ? instead of MEASure:<f>? whenever
    // the target function hasn't changed since the last tick. nil forces
    // the next tick to (re-)select explicitly.
    private var activeDeviceFunction: DMMFunction?

    static let primaryColor = Color(red: 0x1f / 255, green: 0x6f / 255, blue: 0xe0 / 255)

    init() {
        host = UserDefaults.standard.string(forKey: Self.hostDefaultsKey) ?? ""
        primary = MeasurementState(function: .dcVoltage)
    }

    // ---------- connection ----------

    func connect() async {
        // Trim rather than reject: a pasted trailing space or newline is
        // the realistic bad input here and would otherwise fail with an
        // opaque network error.
        host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        UserDefaults.standard.set(host, forKey: Self.hostDefaultsKey)
        await device.setHost(host)
        do {
            try await device.connect()
            connected = true
            connectionError = nil
            activeDeviceFunction = nil

            if let idn = try? await device.identify() {
                deviceModel = idn.model
                firmwareVersion = idn.firmware
                windowTitle = deviceModel.isEmpty
                    ? String(localized: "DMM6500 Control")
                    : String(localized: "\(deviceModel) Control")
            }

            // Adopt whatever function the instrument is already on
            // (front panel, a previous session, etc.) instead of forcing
            // our own default - explicitly picking a function from the
            // UI is optional, not something connecting itself should do.
            // If the reply doesn't parse (e.g. some scanner-card/TSP-only
            // state this app doesn't model), fall back to the built-in
            // default and let a real SENSe:FUNCtion select it.
            if let raw = try? await device.getFunction(), let detected = DMMFunction(scpiReply: raw) {
                primary.function = detected
            } else {
                try? await device.setFunction(primary.function)
            }
            activeDeviceFunction = primary.function
            await loadConfig(for: primary.function)

            startPolling()
        } catch {
            connected = false
            connectionError = error.localizedDescription
            stopPolling()
        }
    }

    /// Called on app quit (see AppDelegate.applicationShouldTerminate) so
    /// the instrument doesn't sit there afterward still reporting an
    /// active remote/LAN session. `try?`: this runs during termination -
    /// nothing meaningful to do with a failure (e.g. device already
    /// unreachable) other than let quitting proceed regardless.
    /// DeviceClient.scpi()'s own ~3s send deadline already bounds how
    /// long this can take, so quitting can't hang indefinitely on an
    /// unreachable device.
    func releaseRemoteControl() async {
        guard connected else { return }
        // Restart continuous acquisition first, then release local
        // control - matches the sequence a direct user report confirmed
        // works, and restores the instrument to the free-running state it
        // was normally in before this app connected, rather than leaving
        // it idle-between-triggers once the front panel takes back over.
        try? await device.restartContinuousTrigger()
        try? await device.logout()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.pollTick()
                let intervalMs = await self.effectivePollIntervalMs
                try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
            }
        }
        // Config (NPLC/range/filter) changes far less often than the
        // reading itself, and a background sync here would otherwise never
        // pick up e.g. a range change made directly on the front panel.
        // Skips any field the user has a pending, not-yet-applied edit in.
        configPollTask?.cancel()
        configPollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                if await self.connected {
                    await self.refreshConfigIfClean()
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        configPollTask?.cancel()
        configPollTask = nil
    }

    // ---------- polling ----------

    // Unlike the UDP3000S supply, the DMM6500 has no separate cheap
    // "mode"-style probe to use as the sole source of connectivity truth -
    // the reading itself doubles as the connectivity check: success flips
    // `connected` back on (so the app recovers on its own once the device
    // comes back), failure flips it off.
    private func pollTick() async {
        let targetFunction = primary.function
        do {
            let value: Double
            if activeDeviceFunction == targetFunction {
                value = try await device.read()
            } else {
                value = try await device.measure(targetFunction)
                activeDeviceFunction = targetFunction
            }
            if !connected {
                connected = true
                connectionError = nil
            }
            primary.value = value
            primary.lastGoodUpdate = Date()
            if primary.statusIsError { primary.setStatus("") }
            // unitLabel ("V DC"), not displayName ("DC Voltage") - the
            // chart/CSV need what's being measured, not which function
            // produced it.
            recordSample(value: value, label: targetFunction.unitLabel, overloadLabel: targetFunction.overloadLabel, color: Self.primaryColor)
        } catch {
            connected = false
            connectionError = error.localizedDescription
            // A dropped connection or desync should force a fresh explicit
            // function select next time, rather than assuming the device
            // is still where we last left it.
            activeDeviceFunction = nil
            primary.setStatus(String(localized: "Read error: \(error.localizedDescription)"), isError: true)
        }
    }

    private func refreshConfigIfClean() async {
        let f = primary.function
        switch f.speedControl {
        case .nplc:
            if !integrationDirty, sampleRate == .custom, let n = try? await device.getNPLC(f) { integrationValue = n }
        case .aperture:
            if !integrationDirty, sampleRate == .custom, let a = try? await device.getAperture(f) { integrationValue = a }
        case .detectorBandwidth:
            // Not a freely-typed field, so there's no dirty flag to
            // respect here - always safe to mirror the device's value.
            if let hz = try? await device.getDetectorBandwidth(f) { bandwidthHz = hz }
        case .none:
            break
        }
        // A single transient query failure shouldn't blank the display's
        // unit scaling for a whole poll cycle - only clear rangeValue when
        // the function genuinely has no range concept; on a failed fetch,
        // just keep showing whatever was last known-good. (Clearing
        // unconditionally here was the cause of an intermittent flash to
        // an unscaled, wrong-decimal-count reading whenever this 2-second
        // background sync happened to hit a hiccup.)
        if f.supportsRange {
            if let r = try? await device.getRange(f) {
                rangeAuto = r.auto
                rangeValue = r.value
                primary.rangeValue = r.value
            }
        } else {
            primary.rangeValue = nil
        }
        if let t = try? await device.getTerminals() {
            terminals = t
        }
        autoZeroEnabled = f.supportsAutoZero ? try? await device.getAutoZero(f) : nil
        inputImpedanceAuto = f == .dcVoltage ? try? await device.getInputImpedanceAuto(f) : nil
        if f.supportsFilter, let flt = try? await device.getFilter(f) {
            filterEnabled = flt.enabled
        }
        if f == .diode, let bias = try? await device.getBiasLevel(f) {
            diodeBiasLevel = bias
        }
    }

    private func loadConfig(for f: DMMFunction) async {
        integrationDirty = false
        switch f.speedControl {
        case .nplc: if let n = try? await device.getNPLC(f) { integrationValue = n }
        case .aperture: if let a = try? await device.getAperture(f) { integrationValue = a }
        case .detectorBandwidth: if let hz = try? await device.getDetectorBandwidth(f) { bandwidthHz = hz }
        case .none: break
        }
        // Unlike refreshConfigIfClean below, this runs right after
        // switching to function `f`, so any previous value is for a
        // *different* function and must not linger - reset first, then
        // only repopulate it if the fetch actually succeeds.
        primary.rangeValue = nil
        if f.supportsRange, let r = try? await device.getRange(f) {
            rangeAuto = r.auto
            rangeValue = r.value
            primary.rangeValue = r.value
        }
        if let t = try? await device.getTerminals() {
            terminals = t
        }
        autoZeroEnabled = f.supportsAutoZero ? try? await device.getAutoZero(f) : nil
        inputImpedanceAuto = f == .dcVoltage ? try? await device.getInputImpedanceAuto(f) : nil
        if f.supportsFilter, let flt = try? await device.getFilter(f) {
            filterEnabled = flt.enabled
        }
        if f == .diode, let bias = try? await device.getBiasLevel(f) {
            diodeBiasLevel = bias
        }
        syncSampleRatePreset()
    }

    func setDiodeBiasLevel(_ value: Double) async {
        diodeBiasLevel = value
        guard connected, primary.function == .diode else { return }
        do {
            try await device.setBiasLevel(.diode, value)
        } catch {
            primary.setStatus(String(localized: "Bias level set failed: \(error.localizedDescription)"), isError: true)
        }
    }

    /// Labels the just-loaded NPLC/bandwidth value with whichever preset
    /// it happens to match (cosmetic - the Sample Rate control shows
    /// "Fast"/"Medium"/"Slow" instead of "Custom" when the device's actual
    /// setting happens to line up), or `.custom` if it doesn't match any
    /// preset. This never writes to the device - it only classifies
    /// whatever was just read, so connecting or switching functions never
    /// changes a setting you didn't touch yourself.
    private func syncSampleRatePreset() {
        let kind = primary.function.speedControl
        let currentValue: Double
        switch kind {
        case .nplc, .aperture: currentValue = integrationValue
        case .detectorBandwidth: currentValue = bandwidthHz
        case .none: return
        }
        if let matched = SampleRatePreset.allCases.first(where: { $0 != .custom && $0.speedValue(for: kind) == currentValue }) {
            sampleRate = matched
        } else {
            sampleRate = .custom
        }
    }

    // ---------- function selection ----------

    func setPrimaryFunction(_ f: DMMFunction) async {
        guard f != primary.function else { return }
        // A recording in progress is one continuous series under one
        // label/unit - switching functions mid-recording would silently
        // mix e.g. volts and ohms under whatever label happened to be set
        // last, rather than warning the user. Stop it instead of trying to
        // reconcile; the data already recorded is left alone (only
        // Clear removes it).
        if graphing { stopGraph() }
        primary.function = f
        primary.value = nil
        guard connected else { return }
        do {
            try await device.setFunction(f)
            activeDeviceFunction = f
        } catch {
            primary.setStatus(String(localized: "Function select failed: \(error.localizedDescription)"), isError: true)
        }
        await loadConfig(for: f)
    }

    // ---------- sample rate ----------

    func setSampleRate(_ preset: SampleRatePreset) async {
        sampleRate = preset
        let kind = primary.function.speedControl
        guard let n = preset.speedValue(for: kind) else { return }
        guard connected, kind != .none else {
            switch kind {
            case .nplc, .aperture: integrationValue = n
            case .detectorBandwidth: bandwidthHz = n
            case .none: break
            }
            return
        }
        do {
            switch kind {
            case .nplc:
                try await device.setNPLC(primary.function, n)
                integrationValue = n
                integrationDirty = false
            case .aperture:
                try await device.setAperture(primary.function, n)
                integrationValue = n
                integrationDirty = false
            case .detectorBandwidth:
                try await device.setDetectorBandwidth(primary.function, n)
                bandwidthHz = n
            case .none:
                break
            }
        } catch {
            primary.setStatus(String(localized: "Speed set failed: \(error.localizedDescription)"), isError: true)
        }
    }

    /// NPLC/Aperture only: applies the freely-typed Advanced field.
    /// Detector bandwidth has no equivalent, since it's a 3-way enumerated
    /// choice applied immediately on selection - see `setBandwidth(_:)`.
    @discardableResult
    func applyCustomIntegration() async -> Bool {
        guard sampleRate == .custom else { integrationDirty = false; return false }
        let kind = primary.function.speedControl
        guard connected, kind == .nplc || kind == .aperture else { integrationDirty = false; return false }
        let clamped = min(max(integrationValue, integrationRange.lowerBound), integrationRange.upperBound)
        do {
            switch kind {
            case .nplc: try await device.setNPLC(primary.function, clamped)
            case .aperture: try await device.setAperture(primary.function, clamped)
            default: break
            }
            integrationValue = clamped
            integrationDirty = false
            return true
        } catch {
            primary.setStatus(String(localized: "Speed set failed: \(error.localizedDescription)"), isError: true)
            return false
        }
    }

    func setBandwidth(_ hz: Double) async {
        bandwidthHz = hz
        guard connected, primary.function.speedControl == .detectorBandwidth else { return }
        do {
            try await device.setDetectorBandwidth(primary.function, hz)
        } catch {
            primary.setStatus(String(localized: "Speed set failed: \(error.localizedDescription)"), isError: true)
        }
    }

    // ---------- range ----------

    func setRangeAuto(_ on: Bool) async {
        rangeAuto = on
        guard connected, primary.function.supportsRange else { return }
        do {
            try await device.setAutoRange(primary.function, on)
        } catch {
            primary.setStatus(String(localized: "Range set failed: \(error.localizedDescription)"), isError: true)
        }
    }

    /// Picks one of `DMMFunction.fixedRangeOptions` (or the dynamic 10A
    /// current option) - applied immediately, since it's a dropdown choice
    /// rather than freely-typed text.
    func setFixedRange(_ value: Double) async {
        guard connected, primary.function.supportsRange else { return }
        do {
            try await device.setRange(primary.function, value)
            rangeAuto = false
            rangeValue = value
            primary.rangeValue = value
        } catch {
            primary.setStatus(String(localized: "Range set failed: \(error.localizedDescription)"), isError: true)
        }
    }

    // ---------- filter ----------

    /// On always means the instrument's own defaults (Repeating, count
    /// 10) - simplified from separately exposing type/count, since in
    /// practice it's just "filter on" or "filter off."
    func setFilterEnabled(_ on: Bool) async {
        filterEnabled = on
        guard connected, primary.function.supportsFilter else { return }
        do {
            if on {
                try await device.setFilter(primary.function, enabled: true, type: .repeating, count: 10)
            } else {
                try await device.setFilter(primary.function, enabled: false)
            }
        } catch {
            primary.setStatus(String(localized: "Filter set failed: \(error.localizedDescription)"), isError: true)
        }
    }
}
