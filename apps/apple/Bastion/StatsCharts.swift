import Charts
import SwiftUI

/// The only file in Bastion that imports Charts.
///
/// Confined on purpose. If Swift Charts ever has to go, one file changes and no
/// pane's structure moves — and `ActivityPanes`, which every screen reads for
/// its shared pieces, stays free of the import.
///
/// **Four rules, and they are not style.** A `NavigationSplitView` sizes its
/// detail column from what the content reports it would ideally like, and a view
/// that asks for more width than the window has collapses the whole layout. The
/// long comments in `LogPane` are what that cost to find the first time. A
/// `Chart` with default configuration is flexible in both axes and reports no
/// content-derived width, so it is safe — but four things would make it unsafe,
/// and all four are banned here:
///
/// 1. **No legend, ever.** A legend is a text row whose ideal width is its
///    longest label, which is the `disclaimer` failure verbatim. Every chart
///    here is explained by a caption sentence inside its `Card` instead.
/// 2. **Explicit axis marks, never automatic.** Automatic marks size themselves
///    from their label text, and at ninety days they want more width than
///    exists. An explicit stride also makes the axis ours, so an OS minor
///    respacing the ticks cannot break a golden with no code change.
/// 3. **No scrollable axes, no visible domain, no enclosing horizontal
///    `ScrollView`.** All three introduce a content-size-driven width, which is
///    the whole disease.
/// 4. **A pinned height and a flexible width, and nothing else.** No
///    `fixedSize` in any orientation, and no chart inside a `safeAreaInset`.
///
/// If the window ever collapses, the falsification test is to swap each chart
/// for `Color.clear.frame(height: 132)`. If it comes back, a chart is the
/// culprit; the fix order is legend, then axis marks, then draw the bars with
/// `Capsule()`s, which is a day of work and not a redesign.
///
/// **No categorical palette, because no chart here plots more than one server.**
/// Cross-server comparison is `RankedBar`, where rows are labelled with text.
/// These are either the whole machine or one server, so a second brand's worth
/// of colours would be invented to distinguish series that do not exist.
enum StatTint {
  /// The thing being measured.
  ///
  /// `AccentColor.colorset` is `design/colors.json`'s own ramp — `hillMid` light
  /// and `plateBottom` dark — so this IS the brand colour, with no constant to
  /// keep in sync with the design tokens and nothing ambient left to pin under a
  /// capture.
  static let primary = Color.accentColor
  /// Failures, and a non-zero exit.
  static let bad = Color.red
  /// A restart, and a figure that is a floor.
  static let warn = Color.orange
  /// What something would have cost without the facade in front of it.
  static let ghost = Color.secondary
}

/// Calls a day, with the failures stacked on what came back.
struct DayBars: View {
  let days: [CallStats.Point]
  /// Days between axis labels. See rule 2.
  let stride: Int

  var body: some View {
    Chart(days) { day in
      // Two marks with literal styles rather than `foregroundStyle(by:)`,
      // deliberately: `by:` conjures a legend and a categorical scale, and the
      // legend is the exact shape that breaks the split view.
      BarMark(x: .value("Day", day.date, unit: .day), y: .value("Calls", day.succeeded))
        .foregroundStyle(StatTint.primary)
      BarMark(x: .value("Day", day.date, unit: .day), y: .value("Failed", day.failures))
        .foregroundStyle(StatTint.bad)
    }
    .chartLegend(.hidden)
    .chartXAxis {
      AxisMarks(values: .stride(by: .day, count: stride)) {
        AxisGridLine()
        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
      }
    }
    .chartYAxis { AxisMarks(position: .leading) }
    .frame(height: 132)
    .frame(maxWidth: .infinity)
  }
}

/// The band between the median and the 95th, with the median drawn on it.
///
/// A band rather than two lines, because it says "most calls landed in here"
/// without implying the 95th is a trend anybody should read a slope off.
struct LatencyBand: View {
  let days: [CallStats.Point]
  let stride: Int

  var body: some View {
    Chart(days) { day in
      if let low = day.latency.p50, let high = day.latency.p95 {
        AreaMark(
          x: .value("Day", day.date, unit: .day),
          yStart: .value("Median", low),
          yEnd: .value("95th", Swift.max(low, high))
        )
        .foregroundStyle(StatTint.primary.opacity(0.18))
      }
      if let median = day.latency.p50 {
        LineMark(x: .value("Day", day.date, unit: .day), y: .value("Median", median))
          .foregroundStyle(StatTint.primary)
          .interpolationMethod(.monotone)
      }
    }
    .chartLegend(.hidden)
    .chartXAxis {
      AxisMarks(values: .stride(by: .day, count: stride)) {
        AxisGridLine()
        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading) { value in
        AxisGridLine()
        AxisValueLabel {
          if let milliseconds = value.as(Int.self) {
            Text(CallStatsRollup.duration(milliseconds: milliseconds))
          }
        }
      }
    }
    .frame(height: 132)
    .frame(maxWidth: .infinity)
  }
}
