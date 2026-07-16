import SwiftUI
import Foundation

enum DMMFunctionCategory: String, CaseIterable {
    case voltage = "Voltage"
    case current = "Current"
    case resistance = "Resistance"
    case other = "Other"

    // Section(category.rawValue) would display the raw English case value
    // verbatim (Section<S: StringProtocol> doesn't localize a non-literal
    // String the way Section(LocalizedStringKey) does) - this gives the
    // menu a properly-localized header instead.
    var displayName: String {
        switch self {
        case .voltage: return String(localized: "Voltage")
        case .current: return String(localized: "Current")
        case .resistance: return String(localized: "Resistance")
        case .other: return String(localized: "Other")
        }
    }
}

/// Which SCPI mechanism controls a function's measurement speed - mutually
/// exclusive per function. Confirmed against real hardware: AC functions
/// use `DETector:BANDwidth` (enumerated 3/30/300 Hz), not `NPLCycles` or
/// `APERture`; Frequency/Period use `APERture` (seconds) and reject NPLC
/// entirely - per the manual (Section 4, p.4-68/4-69): "When using NPLCs
/// to adjust the rate, frequency and period cannot be set. However, when
/// using aperture to adjust the rate, aperture can be set for both
/// frequency and period."
enum SpeedControlKind {
    case nplc
    case detectorBandwidth
    case aperture
    case none
}

/// The only three values this instrument's `DETector:BANDwidth` accepts.
let detectorBandwidthOptionsHz: [Double] = [3, 30, 300]

/// Diode test/bias current options (`SENSe:DIODe:BIAS:LEVel`) - the only
/// four values the manual documents; default out of reset is 1 mA.
let diodeBiasOptions: [RangeOption] = [
    (1e-5, "10 µA"), (1e-4, "100 µA"), (1e-3, "1 mA"), (1e-2, "10 mA"),
].map(RangeOption.init)

/// One entry in a function's fixed-range dropdown - `value` in the base
/// SI unit (as sent to `RANGe`), `label` in the instrument's own
/// conventional unit prefix (e.g. "100 mV", "10 kΩ").
struct RangeOption: Identifiable, Hashable {
    let value: Double
    let label: String
    var id: Double { value }
}

/// The 12 general-purpose measurement functions this app supports.
/// Deliberately excludes anything that only makes sense with scanner
/// cards, TSP, buffers, the trigger model, or the digitizer mode.
enum DMMFunction: String, CaseIterable, Identifiable, Hashable {
    case dcVoltage, acVoltage, dcCurrent, acCurrent
    case resistance2W, resistance4W
    case diode, capacitance, continuity, temperature, frequency, period

    var id: String { rawValue }

    /// Used both as the quoted argument to `SENSe:FUNCtion "<node>"` and as
    /// the path node in `SENSe:<node>:NPLCycles`, `:AVERage:*`, `:RANGe:*`,
    /// and `MEASure:<node>?`.
    var scpiNode: String {
        switch self {
        case .dcVoltage: return "VOLT:DC"
        case .acVoltage: return "VOLT:AC"
        case .dcCurrent: return "CURR:DC"
        case .acCurrent: return "CURR:AC"
        case .resistance2W: return "RES"
        case .resistance4W: return "FRES"
        case .diode: return "DIOD"
        case .capacitance: return "CAP"
        case .continuity: return "CONT"
        case .temperature: return "TEMP"
        case .frequency: return "FREQ"
        case .period: return "PER"
        }
    }

    /// Parses a `SENSe:FUNCtion?` reply back into a case, so the app can
    /// adopt whatever function is already active on the instrument (front
    /// panel, previous session, etc.) instead of assuming one. Tolerant of
    /// the abbreviated default forms the instrument may echo back (e.g.
    /// "VOLT" alone meaning DC, since ":DC" is the optional default node).
    init?(scpiReply raw: String) {
        let upper = raw.trimmingCharacters(in: .whitespaces).uppercased()
        switch upper {
        case "VOLT", "VOLT:DC": self = .dcVoltage
        case "VOLT:AC": self = .acVoltage
        case "CURR", "CURR:DC": self = .dcCurrent
        case "CURR:AC": self = .acCurrent
        case "RES": self = .resistance2W
        case "FRES": self = .resistance4W
        case "DIOD": self = .diode
        case "CAP": self = .capacitance
        case "CONT": self = .continuity
        case "TEMP": self = .temperature
        case "FREQ": self = .frequency
        case "PER": self = .period
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .dcVoltage: return String(localized: "DC Voltage")
        case .acVoltage: return String(localized: "AC Voltage")
        case .dcCurrent: return String(localized: "DC Current")
        case .acCurrent: return String(localized: "AC Current")
        case .resistance2W: return String(localized: "2-Wire Resistance")
        case .resistance4W: return String(localized: "4-Wire Resistance")
        case .diode: return String(localized: "Diode")
        case .capacitance: return String(localized: "Capacitance")
        case .continuity: return String(localized: "Continuity")
        case .temperature: return String(localized: "Temperature")
        case .frequency: return String(localized: "Frequency")
        case .period: return String(localized: "Period")
        }
    }

    var unitSymbol: String {
        switch self {
        case .dcVoltage, .acVoltage, .diode: return "V"
        case .dcCurrent, .acCurrent: return "A"
        case .resistance2W, .resistance4W, .continuity: return "Ω"
        case .capacitance: return "F"
        case .temperature: return "°C"
        case .frequency: return "Hz"
        case .period: return "s"
        }
    }

    /// Unit-based label for the graph/CSV export - e.g. "V DC" rather than
    /// the function's own display name ("DC Voltage"), since what a chart
    /// axis or a CSV column actually needs is what's being measured, not
    /// which SCPI function produced it. Not localized: these are
    /// internationally standardized electrical abbreviations (V, A, DC,
    /// AC), the same convention already used for "NPLC"/"AZero" elsewhere.
    var unitLabel: String {
        switch self {
        case .dcVoltage: return "V DC"
        case .acVoltage: return "V AC"
        case .dcCurrent: return "A DC"
        case .acCurrent: return "A AC"
        default: return unitSymbol
        }
    }

    /// What to show in place of a numeric reading when the instrument
    /// returns its overrange sentinel (see Double.isDMMOverload) - "Open"
    /// for Resistance/Continuity (an open circuit, not an overdriven
    /// signal), "Overflow" otherwise (matches the instrument's own front-
    /// panel wording - originally implemented as "Overload" from a
    /// misremembered label, corrected per direct hardware comparison).
    /// Single source of truth shared by the live readout
    /// (MeasurementCardView), the graph (line gaps), and CSV export (text
    /// instead of the raw 9.9e37 float).
    var overloadLabel: String {
        switch self {
        case .resistance2W, .resistance4W, .continuity: return String(localized: "Open")
        default: return String(localized: "Overflow")
        }
    }

    var category: DMMFunctionCategory {
        switch self {
        case .dcVoltage, .acVoltage: return .voltage
        case .dcCurrent, .acCurrent: return .current
        case .resistance2W, .resistance4W: return .resistance
        case .diode, .capacitance, .continuity, .temperature, .frequency, .period: return .other
        }
    }

    /// Which knob controls this function's measurement speed.
    /// - `.nplc`: DC Voltage/Current, Resistance (2W/4W), Temperature -
    ///   hardware-confirmed. **Diode too** - not hardware-confirmed, but
    ///   the manual gives Diode its own dedicated "Measure Settings" table
    ///   (p.3-35/3-36) and its own row in the Aperture Details table
    ///   (p.12-77) with the same NPLC/Aperture toggle and range as the DC
    ///   functions, rather than the generic shared-boilerplate list that
    ///   turned out to be wrong for Auto Zero - this is a real
    ///   function-specific table, so treated as reliable.
    /// - `.detectorBandwidth`: AC Voltage/Current - hardware-confirmed
    ///   (3/30/300 Hz enumerated).
    /// - `.aperture`: Frequency/Period - hardware-confirmed (user's own
    ///   instrument shows "Aperture" for Frequency) and manual-confirmed
    ///   (p.3-34/3-35, p.4-68/4-69, p.12-77): 2ms-273ms, default 200ms,
    ///   and they explicitly do NOT support NPLC.
    /// - `.none`: Capacitance ("fixed aperture time", p.4-32, no
    ///   Aperture/NPLC row at all in its settings table) and Continuity
    ///   (NPLC "always set to 0.006 PLC", not user-adjustable, p.3-34,
    ///   p.4-23) - both manual-confirmed as fixed/non-adjustable.
    var speedControl: SpeedControlKind {
        switch self {
        case .dcVoltage, .dcCurrent, .resistance2W, .resistance4W, .temperature, .diode: return .nplc
        case .acVoltage, .acCurrent: return .detectorBandwidth
        case .frequency, .period: return .aperture
        case .capacitance, .continuity: return .none
        }
    }

    // Confirmed-by-worked-example in the manual only for DC Voltage/
    // Current and 2-Wire Resistance (p.12-85/86). Every other function
    // listed here (AC Voltage/Current, 4-Wire Resistance, Temperature) is
    // "inferred, not confirmed" - the manual states filtering is
    // unavailable only for digitize functions (which this app doesn't
    // support at all) and never names any of these as excluded, but no
    // worked example exists for them either. Diode/Capacitance/
    // Continuity/Frequency/Period are left OFF here despite being in that
    // same "probably fine, not confirmed" tier - Auto Zero already taught
    // this app that guessing a function into an unverified SCPI command
    // can visibly error on the instrument itself (SCPI -113), so this
    // stays conservative until hardware-tested rather than expanding to
    // match every function the manual doesn't explicitly rule out.
    var supportsFilter: Bool {
        switch self {
        case .dcVoltage, .acVoltage, .dcCurrent, .acCurrent, .resistance2W, .resistance4W, .temperature: return true
        case .diode, .capacitance, .continuity, .frequency, .period: return false
        }
    }

    var supportsRange: Bool {
        switch self {
        case .dcVoltage, .acVoltage, .dcCurrent, .acCurrent, .resistance2W, .resistance4W, .capacitance: return true
        case .diode, .continuity, .temperature, .frequency, .period: return false
        }
    }

    /// Hardware-confirmed: `AZERo?` returns SCPI error -113 "unknown
    /// header" on Continuity, Capacitance, Frequency, and Period (the
    /// command doesn't exist for them at all, despite the manual's shared
    /// applicability table implying otherwise), and isn't available on AC
    /// Voltage/AC Current either. Only query it for the functions below -
    /// sending it to an unsupported function isn't just harmless-and-
    /// ignored on our side, it visibly errors on the instrument itself.
    var supportsAutoZero: Bool {
        switch self {
        case .dcVoltage, .dcCurrent, .resistance2W, .resistance4W, .diode, .temperature: return true
        case .acVoltage, .acCurrent, .capacitance, .continuity, .frequency, .period: return false
        }
    }

    /// The instrument's own fixed range list per function (Reference
    /// Manual, "ranges for each function" table) - offered as a dropdown
    /// alongside Auto rather than free-form entry, since any value sent to
    /// `RANGe` just snaps to the nearest one of these anyway.
    ///
    /// One thing this doesn't model, to keep the picker simple: 4-Wire
    /// Resistance has fewer available ranges when offset compensation is
    /// turned on (not exposed by this app, so the full list is shown).
    /// DC/AC Current's 10A range IS listed below (labeled "10A (Rear)")
    /// even though it only works on the rear AMPS terminals - the UI
    /// disables that one option rather than hiding it, so it's still
    /// visible as a hint that it exists (see ContentView.rangeControl).
    var fixedRangeOptions: [RangeOption] {
        switch self {
        case .dcVoltage:
            return [(0.1, "100 mV"), (1, "1 V"), (10, "10 V"), (100, "100 V"), (1000, "1000 V")].map(RangeOption.init)
        case .acVoltage:
            return [(0.1, "100 mV"), (1, "1 V"), (10, "10 V"), (100, "100 V"), (750, "750 V")].map(RangeOption.init)
        case .dcCurrent:
            return [(0.00001, "10 µA"), (0.0001, "100 µA"), (0.001, "1 mA"), (0.01, "10 mA"), (0.1, "100 mA"), (1, "1 A"), (3, "3 A"), (10, "10A (Rear)")].map(RangeOption.init)
        case .acCurrent:
            return [(0.001, "1 mA"), (0.01, "10 mA"), (0.1, "100 mA"), (1, "1 A"), (3, "3 A"), (10, "10A (Rear)")].map(RangeOption.init)
        case .resistance2W:
            return [(10, "10 Ω"), (100, "100 Ω"), (1000, "1 kΩ"), (10000, "10 kΩ"), (100_000, "100 kΩ"), (1_000_000, "1 MΩ"), (10_000_000, "10 MΩ"), (100_000_000, "100 MΩ")].map(RangeOption.init)
        case .resistance4W:
            return [(1, "1 Ω"), (10, "10 Ω"), (100, "100 Ω"), (1000, "1 kΩ"), (10000, "10 kΩ"), (100_000, "100 kΩ"), (1_000_000, "1 MΩ"), (10_000_000, "10 MΩ"), (100_000_000, "100 MΩ")].map(RangeOption.init)
        case .capacitance:
            // 1 mF removed - user confirmed it doesn't exist on their unit.
            return [(1e-9, "1 nF"), (10e-9, "10 nF"), (100e-9, "100 nF"), (1e-6, "1 µF"), (10e-6, "10 µF"), (100e-6, "100 µF")].map(RangeOption.init)
        case .diode, .continuity, .temperature, .frequency, .period:
            return []
        }
    }
}

enum FilterType: String, CaseIterable, Identifiable, Hashable {
    case moving = "MOV"
    case repeating = "REP"

    var id: String { rawValue }
    var scpiValue: String { rawValue }
    var displayName: String {
        switch self {
        case .moving: return String(localized: "Moving")
        case .repeating: return String(localized: "Repeating")
        }
    }

    init?(scpi: String) {
        let upper = scpi.uppercased()
        if upper.hasPrefix("MOV") { self = .moving }
        else if upper.hasPrefix("REP") { self = .repeating }
        else { return nil }
    }
}

/// A named measurement speed. Rather than separately tuning an integration
/// time *and* a poll interval (which could drift out of sync with each
/// other), a preset only picks the speed value appropriate to whichever
/// mechanism the current function actually uses (NPLC count or detector
/// bandwidth in Hz) - AppModel derives the poll interval from that same
/// value, since the instrument can't return a reading faster than it takes
/// to integrate/settle one. `.custom` defers to AppModel's own stored
/// value instead of a fixed number here.
enum SampleRatePreset: String, CaseIterable, Identifiable, Hashable {
    case fast, medium, slow, custom

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .fast: return String(localized: "Fast")
        case .medium: return String(localized: "Medium")
        case .slow: return String(localized: "Slow")
        case .custom: return String(localized: "Custom")
        }
    }

    /// nil for `.custom` (defer to AppModel's stored value) and for a
    /// `kind` the preset has no notion of speed for (`.none`).
    func speedValue(for kind: SpeedControlKind) -> Double? {
        switch (self, kind) {
        case (.fast, .nplc): return 0.1
        case (.medium, .nplc): return 1
        case (.slow, .nplc): return 10
        // Detector bandwidth only accepts 3/30/300 Hz on this instrument -
        // higher bandwidth settles faster (less low-frequency accuracy),
        // so Fast maps to the widest bandwidth and Slow to the narrowest.
        case (.fast, .detectorBandwidth): return 300
        case (.medium, .detectorBandwidth): return 30
        case (.slow, .detectorBandwidth): return 3
        // Frequency/Period aperture: manual-confirmed range 2ms-273ms,
        // default 200ms. Slow maps to the instrument's own default rather
        // than the range's extreme end.
        case (.fast, .aperture): return 0.002
        case (.medium, .aperture): return 0.02
        case (.slow, .aperture): return 0.2
        default: return nil
        }
    }
}

/// The current measurement readout shown in the UI. Kept as its own small
/// ObservableObject (rather than plain @Published properties on AppModel)
/// so the card view doesn't need to reach through AppModel for every field.
@MainActor
final class MeasurementState: ObservableObject {
    @Published var function: DMMFunction
    @Published var value: Double?
    @Published var lastGoodUpdate: Date?
    @Published var statusMessage: String = ""
    @Published var statusIsError = false
    // Mirrors the device's current range for this function (nil if
    // unknown or the function has no adjustable range) - used purely for
    // display, to pick the same V/mV/µV-style unit scaling the
    // instrument's own front panel uses instead of always showing the
    // base SI unit.
    @Published var rangeValue: Double?

    init(function: DMMFunction) {
        self.function = function
    }

    func setStatus(_ message: String, isError: Bool = false) {
        statusMessage = message
        statusIsError = isError
    }
}

/// 9.9e37 is this instrument's overrange/open-circuit sentinel (see
/// DeviceClient.measure's doc comment) - anything at or above that
/// magnitude is a placeholder, not a real measurement. Shared by the live
/// readout, the graph, and CSV export so all three agree on the same
/// threshold.
extension Double {
    var isDMMOverload: Bool { abs(self) >= 9e37 }
}

// Not Identifiable-via-UUID: within one series `t` is strictly increasing,
// so views use ForEach(id: \.t) instead of allocating a UUID per sample.
struct GraphPoint {
    let t: Double
    let y: Double
    // Marks an overrange/open-circuit sample rather than a real reading -
    // GraphView excludes these from the plotted line and the y-axis
    // range (a 9.9e37 sentinel would otherwise dwarf every real value),
    // and CSV export substitutes GraphSeries.overloadLabel for the value
    // column instead of the raw sentinel float.
    let isOverload: Bool
}

final class GraphSeries {
    let color: Color
    var label: String
    var overloadLabel: String
    var points: [GraphPoint] = []

    init(color: Color, label: String, overloadLabel: String) {
        self.color = color
        self.label = label
        self.overloadLabel = overloadLabel
    }
}
