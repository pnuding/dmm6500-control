import SwiftUI
import Foundation

/// The reading readout card. Adapted from udp3000s-control's
/// ChannelCardView, minus the setpoint/protection controls a DMM has no
/// equivalent of.
///
/// The function name in the header doubles as the function picker: tapping
/// it opens a menu instead of needing a separate always-visible Picker
/// section elsewhere in the window.
struct MeasurementCardView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var state: MeasurementState
    var color: Color

    var body: some View {
        // Ticks once a second purely to re-check "has it been too long
        // since the last successful read" - readings themselves are still
        // driven by the poll loop; this only decides when to swap them for
        // placeholder dashes if that loop hasn't gotten anything back
        // recently.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let stale = !model.connected || (state.lastGoodUpdate.map { context.date.timeIntervalSince($0) > 5 } ?? true)
            // Not a uniform VStack spacing: the header->reading gap (12,
            // matching the card's original spacing) is kept as the
            // reference gap, while the gap before the status/error row is
            // deliberately tighter (4) - a uniform spacing here left a lot
            // of visually "dead" space below the number, since the
            // reserved status row and the reduced bottom padding already
            // add their own room without needing full spacing too.
            VStack(alignment: .leading, spacing: 0) {
                header
                readingRow(stale: stale)
                    .padding(.top, 12)
                // Reserved height regardless of content, so an error
                // appearing or clearing never resizes the card.
                Text(state.statusMessage.isEmpty ? " " : state.statusMessage)
                    .font(.callout)
                    .foregroundStyle(state.statusIsError ? .red : .secondary)
                    .frame(height: 18, alignment: .leading)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)
            .frame(minWidth: 340, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(color.opacity(0.6), lineWidth: 2)
            )
        }
    }

    // Read-only device-state badges, abbreviated the way the instrument
    // itself does, in the same row as the function picker.
    private var badgesRow: some View {
        HStack(spacing: 6) {
            badge(
                model.terminals == "REAR" ? String(localized: "Rear") : String(localized: "Front"),
                help: "Input terminals currently selected for this measurement (front or rear panel)"
            )
            // Only shown when on, like the instrument's own annunciator -
            // there's no "AZero Off" equivalent on the device itself.
            if model.autoZeroEnabled == true {
                badge(String(localized: "AZero"), help: "Auto Zero is on: the instrument periodically re-zeros itself to cancel offset drift")
            }
            if state.function == .dcVoltage, let impedanceAuto = model.inputImpedanceAuto {
                badge(
                    impedanceAuto ? String(localized: "AutoΩ") : String(localized: "10 MΩ"),
                    help: impedanceAuto
                        ? "DC Voltage input impedance: automatic (>10 GΩ on the lower ranges)"
                        : "DC Voltage input impedance: fixed 10 MΩ"
                )
            }
        }
    }

    private func badge(_ text: String, help: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .help(help)
    }

    private var header: some View {
        HStack(spacing: 8) {
            badgesRow
            Spacer()
            functionMenu
        }
    }

    private var functionMenu: some View {
        Menu {
            ForEach(DMMFunctionCategory.allCases, id: \.self) { category in
                Section(category.displayName) {
                    ForEach(DMMFunction.allCases.filter { $0.category == category }) { f in
                        Button(f.displayName) { Task { await model.setPrimaryFunction(f) } }
                    }
                }
            }
        } label: {
            // No manual chevron here - .menuStyle(.borderlessButton)
            // already appends its own disclosure indicator after the
            // label, so one was showing up twice (ours large from
            // inheriting .title3, the system's own small).
            Text(state.function.displayName)
                .font(.title3.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Change the measurement function")
    }

    private func readingRow(stale: Bool) -> some View {
        let layout = Self.layout(for: state)
        let text: String
        if stale || state.value == nil {
            text = Self.placeholder(integerDigits: layout.integerDigits, decimals: layout.decimals, symbol: "--")
        } else if let v = state.value, v.isDMMOverload {
            // The instrument returns 9.9e37 for an overrange reading. On
            // Resistance/Continuity that means an open circuit, not
            // really an "overload" in the overdriven-signal sense.
            text = Self.placeholder(integerDigits: layout.integerDigits, decimals: layout.decimals, symbol: state.function.overloadLabel)
        } else {
            let scaledValue = state.value! * layout.multiplier
            // layout's digit budget is sized for whatever range
            // rangeValue last reported - polled only every 2s, far slower
            // than live readings (every poll tick). If auto-ranging
            // silently jumps the instrument to a different actual range
            // in between, a genuine (non-overload-sentinel) reading can
            // arrive that no longer fits this stale budget at all -
            // signAndPad's printf format only enforces a *minimum* width,
            // so an unexpectedly large value prints in full rather than
            // being clipped, which is what actually produced the
            // momentary "1000000.0000"-style blips that blew out the
            // card's layout for a frame. Holding the placeholder here
            // instead - same idea as the stale-reading branch above -
            // until rangeValue catches up on its next poll.
            let maxRepresentable = pow(10.0, Double(layout.integerDigits))
            if abs(scaledValue) >= maxRepresentable {
                text = Self.placeholder(integerDigits: layout.integerDigits, decimals: layout.decimals, symbol: "--")
            } else {
                text = Self.signAndPad(scaledValue, integerDigits: layout.integerDigits, decimals: layout.decimals)
            }
        }
        return HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text(text)
                .font(.system(size: 56, weight: .semibold, design: .monospaced))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(layout.unit)
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 300, alignment: .leading)
    }

    // ---------- fixed-width, unit-scaled number formatting ----------
    //
    // Two problems this solves together: (1) the digit count shouldn't
    // change from one reading to the next just because the value crept
    // past an integer boundary - that reads as the display "jumping
    // around" - and (2) the instrument's own front panel doesn't always
    // show the base SI unit; on a 100mV range it shows e.g. "45.3000 mV"
    // rather than "0.0453 V", trading a unit prefix for more significant
    // digits. Both come from the same fix: derive the unit prefix and
    // decimal count from the *range* (which changes rarely), not from the
    // live reading's own magnitude (which changes every sample).

    private struct Layout {
        let multiplier: Double
        let unit: String
        let integerDigits: Int
        let decimals: Int
    }

    private static func layout(for state: MeasurementState) -> Layout {
        let function = state.function
        if function.supportsRange, let range = state.rangeValue, range > 0 {
            let scale = siScale(rangeMagnitude: range)
            return Layout(multiplier: scale.multiplier, unit: scale.prefixSymbol + function.unitSymbol, integerDigits: scale.integerDigits, decimals: scale.decimals)
        }
        // No range to anchor to (function has none, or it hasn't loaded
        // yet right after connecting/switching) - fall back to a fixed,
        // function-specific layout so the display is still stable, just
        // without unit-prefix scaling.
        let fallback = fallbackLayout(for: function)
        return Layout(multiplier: 1, unit: function.unitSymbol, integerDigits: fallback.integerDigits, decimals: fallback.decimals)
    }

    /// Picks an SI prefix from the range's magnitude (e.g. a 100mV range
    /// scales to "m", 10V to no prefix, 10kΩ to "k"), then sizes the
    /// integer/decimal digit counts so the scaled range's full-scale value
    /// plus its decimals together land around 7 total digits - roughly
    /// matching this instrument's ~6.5-digit display resolution.
    private static func siScale(rangeMagnitude: Double) -> (multiplier: Double, prefixSymbol: String, integerDigits: Int, decimals: Int) {
        let magnitude = max(abs(rangeMagnitude), 1e-12)
        let order = Int(floor(log10(magnitude)))
        let exp3 = min(max(Int(floor(Double(order) / 3.0)) * 3, -9), 9)
        let prefixSymbol: String
        switch exp3 {
        case -9: prefixSymbol = "n"
        case -6: prefixSymbol = "µ"
        case -3: prefixSymbol = "m"
        case 3: prefixSymbol = "k"
        case 6: prefixSymbol = "M"
        case 9: prefixSymbol = "G"
        default: prefixSymbol = ""
        }
        let multiplier = pow(10.0, Double(-exp3))
        let scaledRangeMagnitude = magnitude * multiplier
        let integerDigits = max(1, Int(floor(log10(scaledRangeMagnitude))) + 1)
        let decimals = max(0, 7 - integerDigits)
        return (multiplier, prefixSymbol, integerDigits, decimals)
    }

    /// Used only for functions with no range to anchor to (Diode,
    /// Continuity, Temperature, Frequency, Period) - reasonable fixed
    /// guesses for this instrument's typical spans, not derived from any
    /// live reading, so they stay stable sample-to-sample.
    private static func fallbackLayout(for function: DMMFunction) -> (integerDigits: Int, decimals: Int) {
        switch function {
        // Hardware-confirmed: the device's own front panel shows 6
        // decimals for Diode (e.g. "0.000043 V"), not the originally
        // guessed 4 - this app had no way to query Diode's range to
        // derive the digit count the way supportsRange functions do, so
        // it was a guess until directly compared against the unit.
        case .diode: return (1, 6)
        case .continuity: return (4, 1)
        case .temperature: return (4, 2)
        case .frequency: return (7, 3)
        case .period: return (2, 6)
        case .dcVoltage, .acVoltage, .dcCurrent, .acCurrent, .resistance2W, .resistance4W, .capacitance:
            // supportsRange functions, shown only in the brief window
            // before their range has loaded - same 7-total-digit target as
            // siScale, so this doesn't visually stand out from the normal
            // scaled layout if it's ever glimpsed.
            return (2, 5)
        }
    }

    /// The `% ` printf flag reserves exactly one column for the sign
    /// (a literal space in its place for a positive value, "-" for
    /// negative), and plain width padding (no "0" flag) fills the rest
    /// with blanks rather than leading zeros - so "45.3" and "-45.3" stay
    /// digit-aligned without looking like an odometer.
    private static func signAndPad(_ scaledValue: Double, integerDigits: Int, decimals: Int) -> String {
        let totalWidth = 1 + integerDigits + (decimals > 0 ? 1 + decimals : 0)
        return String(format: "% \(totalWidth).\(decimals)f", scaledValue)
    }

    /// Same total width as a live reading at this layout, so a stale/
    /// overload placeholder doesn't shift the card's contents when a real
    /// reading resumes.
    private static func placeholder(integerDigits: Int, decimals: Int, symbol: String) -> String {
        let totalWidth = 1 + integerDigits + (decimals > 0 ? 1 + decimals : 0) // +1 reserves the sign slot
        guard symbol.count < totalWidth else { return symbol }
        return String(repeating: " ", count: totalWidth - symbol.count) + symbol
    }
}
