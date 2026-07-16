import SwiftUI
import Charts

struct GraphView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(model.graphing ? "Stop" : "Start") {
                    model.graphing ? model.stopGraph() : model.startGraph()
                }
                .buttonStyle(.borderedProminent)
                .help(model.graphing ? "Stop recording readings" : "Start recording readings")
                Button("Clear") { model.clearGraph() }
                    .help("Clear all recorded data")
                Spacer()
                Button("Export CSV…") { model.exportCSV() }
                    .help("Save recorded data as a CSV file")
            }

            if let series = model.graphSeries {
                chartSection(series: series)
            } else {
                Spacer()
                Text("No data recorded yet. Click Start to begin.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func chartSection(series: GraphSeries) -> some View {
        // Overload/open-circuit samples (9.9e37) are excluded from the
        // y-domain entirely - including them would make the axis span
        // from a real reading to ~1e38, squashing every genuine value into
        // an invisible sliver at the bottom.
        let validPoints = series.points.filter { !$0.isOverload }
        let maxT = max(1, series.points.map(\.t).max() ?? 1)
        let yMax = max(0.000001, (validPoints.map(\.y).max() ?? 0) * 1.1)
        let yMin = min(0, (validPoints.map(\.y).min() ?? 0) * 1.1)
        return VStack(alignment: .leading, spacing: 4) {
            Text(series.label).font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(downsampled(series.points), id: \.t) { point in
                    // A nil y value is Swift Charts' documented way to
                    // represent a missing/invalid sample - it leaves a
                    // visible gap in the line at that x, rather than
                    // connecting straight through. (An earlier attempt
                    // split overload runs into separate categorical
                    // "series" via foregroundStyle(by:) instead - that
                    // crashed the Charts framework itself on a resistance
                    // recording, almost certainly because probe
                    // open/close during hands-on testing can create
                    // dozens of segments in a single session, and that API
                    // is meant for a handful of fixed categories, not an
                    // unbounded, ever-growing count.)
                    // Double.nan, not a sentinel number: Charts can't
                    // compare/render a NaN coordinate, so it skips drawing
                    // a line segment through it, which is what actually
                    // produces the visible gap - Optional<Double> isn't a
                    // Plottable this framework version accepts for
                    // .value(_:_:), and multiple real values (even 0)
                    // would just connect straight through like normal
                    // data.
                    let y: Double = point.isOverload ? .nan : point.y
                    LineMark(
                        x: .value("t", point.t),
                        y: .value("value", y)
                    )
                    .foregroundStyle(series.color)
                }
            }
            .chartXScale(domain: 0...maxT)
            .chartYScale(domain: yMin...yMax)
            .chartXAxisLabel("Time (s)")
            .chartYAxis {
                AxisMarks(values: .automatic) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let d = value.as(Double.self) {
                            Text(Self.siAxisLabel(d))
                        }
                    }
                }
            }
            .frame(minHeight: 140, maxHeight: .infinity)
        }
    }

    // ---------- y-axis tick formatting ----------
    //
    // Charts' default axis labels print the raw double ("5000000",
    // "1.0e-12"), which is unreadable for the wide dynamic range this app's
    // functions span (picofarads to megohms). Scales to the nearest SI
    // prefix instead, e.g. "5M", "1p" - same prefix ladder as
    // MeasurementCardView's readout scaling, but independent of it since
    // axis ticks pick their own magnitude per value rather than anchoring
    // to the function's range.

    private static func siAxisLabel(_ value: Double) -> String {
        guard value != 0 else { return "0" }
        let sign = value < 0 ? "-" : ""
        let magnitude = abs(value)
        let order = Int(floor(log10(magnitude)))
        let exp3 = min(max(Int(floor(Double(order) / 3.0)) * 3, -12), 12)
        let prefix: String
        switch exp3 {
        case -12: prefix = "p"
        case -9: prefix = "n"
        case -6: prefix = "µ"
        case -3: prefix = "m"
        case 3: prefix = "k"
        case 6: prefix = "M"
        case 9: prefix = "G"
        case 12: prefix = "T"
        default: prefix = ""
        }
        let scaled = magnitude / pow(10.0, Double(exp3))
        return "\(sign)\(Self.trimmedNumber(scaled))\(prefix)"
    }

    /// One decimal place, trimmed to an integer when it's a whole number -
    /// "5" not "5.0", but "2.5" kept as-is.
    private static func trimmedNumber(_ v: Double) -> String {
        let rounded = (v * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }

    // Display-only decimation: the chart rebuilds a LineMark per point on
    // every update, so an hours-long recording (tens of thousands of
    // samples) would get very sluggish. Strided sampling caps rendering at
    // ~500 marks per series regardless of recording length.
    private func downsampled(_ points: [GraphPoint]) -> [GraphPoint] {
        let maxPoints = 500
        guard points.count > maxPoints else { return points }
        let step = (points.count + maxPoints - 1) / maxPoints
        var out = [GraphPoint]()
        out.reserveCapacity(maxPoints + 1)
        var i = 0
        while i < points.count {
            out.append(points[i])
            i += step
        }
        // Always keep the newest sample so the line's leading edge tracks
        // live rather than lagging up to `step` samples behind.
        if let last = points.last, out.last!.t != last.t {
            out.append(last)
        }
        return out
    }
}
