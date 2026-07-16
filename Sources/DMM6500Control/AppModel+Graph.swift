import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension AppModel {
    func recordSample(value: Double, label: String, overloadLabel: String, color: Color) {
        guard graphing else { return }
        if graphSeries == nil {
            graphSeries = GraphSeries(color: color, label: label, overloadLabel: overloadLabel)
        }
        graphSeries?.label = label
        graphSeries?.overloadLabel = overloadLabel
        let t = Date().timeIntervalSince(graphStartTime)
        graphSeries?.points.append(GraphPoint(t: t, y: value, isOverload: value.isDMMOverload))
        // Publishing per sample would mean an app-wide invalidation on
        // every poll tick, rebuilding the whole chart each time. The data
        // itself is still recorded at full rate - only the UI notification
        // is coalesced to ~1Hz.
        let now = Date()
        if now.timeIntervalSince(lastGraphPublish) >= 1.0 {
            lastGraphPublish = now
            objectWillChange.send()
        }
    }

    func startGraph() {
        graphSeries = nil
        graphStartTime = Date()
        lastGraphPublish = .distantPast
        graphing = true
    }

    func stopGraph() {
        graphing = false
    }

    func clearGraph() {
        graphSeries = nil
    }

    /// Ported from udp3000s-control's exportCSV(), simplified for a single
    /// measurement stream instead of a per-channel dictionary. Reads the
    /// series' raw, full-resolution `points` directly - NOT
    /// GraphView.downsampled(_:)'s ~500-point display subset - so the
    /// export always has every recorded sample regardless of how long the
    /// chart itself has been decimating on screen.
    func exportCSV() {
        guard let series = graphSeries, !series.points.isEmpty else { return }
        var rows = [["time_s", "value", "unit"]]
        for p in series.points {
            // Same wording as the live readout (DMMFunction.overloadLabel)
            // instead of the raw 9.9e37 sentinel float, which is otherwise
            // meaningless outside the app.
            let valueField = p.isOverload ? series.overloadLabel : String(format: "%.6f", p.y)
            rows.append([
                String(format: "%.3f", p.t),
                valueField,
                series.label,
            ])
        }
        let csv = rows.map { $0.joined(separator: ",") }.joined(separator: "\n")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "dmm6500-log-\(stamp).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        // begin(), not runModal(): the modal variant parks the main run
        // loop while the dialog is open, stalling the poll loop (and any
        // in-progress graph recording) the whole time the user browses
        // for a save location.
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // AppKit calls this on the main thread; assumeIsolated makes
            // that visible to the compiler so the alert (MainActor-bound
            // API) can be shown from here.
            MainActor.assumeIsolated {
                do {
                    try csv.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = String(localized: "Could not save CSV")
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }
}
