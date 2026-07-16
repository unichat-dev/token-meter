// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Charts
import SwiftUI

/// Window scene identifiers.
enum WindowID {
    static let details = "details"
}

/// Which calendar period the details window shows.
enum DetailsPeriod: String, CaseIterable, Identifiable {
    case day = "Day"
    case week = "Week"
    case month = "Month"

    var id: String { rawValue }

    var calendarComponent: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    /// Chart bin size for this period.
    var binComponent: Calendar.Component {
        switch self {
        case .day: .hour
        case .week, .month: .day
        }
    }
}

/// Usage history window: tokens and estimated cost over time, per-model and
/// per-project breakdowns, day/week/month navigation. All numbers are
/// log-derived estimates.
struct DetailsWindowView: View {
    @Environment(AppModel.self) private var model

    @State private var period: DetailsPeriod = .day
    /// 0 = the current period, -1 = previous, …
    @State private var periodOffset = 0
    @State private var breakdownDimension: BreakdownDimension = .model
    @State private var chartMetric: ChartMetric = .tokens

    enum BreakdownDimension: String, CaseIterable {
        case model = "By model"
        case project = "By project"
    }

    enum ChartMetric: String, CaseIterable {
        case tokens = "Tokens"
        case cost = "Est. cost"
    }

    private var calendar: Calendar { .current }

    /// The date interval currently displayed.
    private var interval: DateInterval? {
        guard let anchor = calendar.date(
            byAdding: period.calendarComponent,
            value: periodOffset,
            to: .now
        ) else { return nil }
        return calendar.dateInterval(of: period.calendarComponent, for: anchor)
    }

    private var rangeEvents: [UsageEvent] {
        guard let interval else { return [] }
        return model.events(in: interval)
    }

    private var rangeSummary: UsageSummary {
        var summary = UsageSummary()
        for event in rangeEvents { summary.include(event) }
        return summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if rangeEvents.isEmpty {
                emptyState
            } else {
                summaryRow
                timeChart
                breakdownSection
            }
            Spacer(minLength: 0)
            footerNote
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 520)
        .onAppear {
            model.refreshNow()
        }
    }

    // MARK: - Header / period navigation

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Period", selection: $period) {
                ForEach(DetailsPeriod.allCases) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .onChange(of: period) {
                periodOffset = 0
            }

            HStack(spacing: 4) {
                Button {
                    periodOffset -= 1
                } label: {
                    Image(systemName: "chevron.left")
                }
                Button {
                    periodOffset += 1
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(periodOffset >= 0)
            }
            .controlSize(.small)

            Text(intervalLabel)
                .font(.headline)

            if periodOffset != 0 {
                Button("Now") { periodOffset = 0 }
                    .controlSize(.small)
            }

            Spacer()
            EstimatedBadge()
        }
    }

    private var intervalLabel: String {
        guard let interval else { return "" }
        switch period {
        case .day:
            return interval.start.formatted(date: .abbreviated, time: .omitted)
        case .week, .month:
            // End is exclusive — show the last included day.
            let lastDay = interval.end.addingTimeInterval(-1)
            return "\(interval.start.formatted(date: .abbreviated, time: .omitted)) – \(lastDay.formatted(date: .abbreviated, time: .omitted))"
        }
    }

    // MARK: - Summary

    private var rangeCosts: CostEngine.Totals {
        CostEngine.totals(for: rangeEvents, resolver: model.pricingResolver)
    }

    private var summaryRow: some View {
        HStack(spacing: 8) {
            SummaryTile(title: "Total", value: rangeSummary.tokens.total, systemImage: "sum")
            SummaryTile(title: "Input", value: rangeSummary.tokens.input, systemImage: "arrow.down.circle")
            SummaryTile(title: "Output", value: rangeSummary.tokens.output, systemImage: "arrow.up.circle")
            SummaryTile(
                title: "Cache",
                value: rangeSummary.tokens.cacheRead + rangeSummary.tokens.cacheCreation,
                systemImage: "archivebox"
            )
            SummaryTile(title: "Messages", value: rangeSummary.eventCount, systemImage: "text.bubble")
            costTile
        }
    }

    private var costTile: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Est. cost", systemImage: "dollarsign.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(rangeCosts.costIfAnyPriced.map {
                $0.formatted(.currency(code: "USD").precision(.fractionLength(2)))
            } ?? "—")
                .font(.system(.body, design: .rounded, weight: .semibold))
                .contentTransition(.numericText())
                .help(costHelp)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private var costHelp: String {
        if rangeCosts.unpricedModels.isEmpty {
            return "Estimated from your pricing table — not an invoice."
        }
        return "Estimated from your pricing table — not an invoice. Excludes unpriced models: \(rangeCosts.unpricedModels.sorted().joined(separator: ", "))."
    }

    // MARK: - Time chart

    private var binnedRows: [UsageAggregation.TimeBinRow] {
        UsageAggregation.timeBins(
            events: rangeEvents,
            component: period.binComponent,
            calendar: calendar
        )
    }

    private var costBinnedRows: [UsageAggregation.ValueBinRow] {
        let resolver = model.pricingResolver
        return UsageAggregation.valueTimeBins(
            events: rangeEvents,
            component: period.binComponent,
            calendar: calendar
        ) { event in
            guard let pricing = resolver.pricing(for: event.model) else { return nil }
            return NSDecimalNumber(decimal: CostEngine.cost(tokens: event.tokens, pricing: pricing))
                .doubleValue
        }
    }

    private var timeChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(chartMetric == .tokens ? "Tokens over time" : "Estimated cost over time")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Picker("Metric", selection: $chartMetric) {
                    ForEach(ChartMetric.allCases, id: \.self) { metric in
                        Text(metric.rawValue).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
            }

            switch chartMetric {
            case .tokens:
                Chart(binnedRows) { row in
                    BarMark(
                        x: .value("Time", row.binStart, unit: period.binComponent == .hour ? .hour : .day),
                        y: .value("Tokens", row.tokens)
                    )
                    .foregroundStyle(by: .value("Model", row.model))
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let tokens = value.as(Int.self) {
                                Text(tokens.formatted(.number.notation(.compactName)))
                            }
                        }
                    }
                }
                .frame(height: 180)
            case .cost:
                Chart(costBinnedRows) { row in
                    BarMark(
                        x: .value("Time", row.binStart, unit: period.binComponent == .hour ? .hour : .day),
                        y: .value("Cost", row.value)
                    )
                    .foregroundStyle(by: .value("Model", row.model))
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let cost = value.as(Double.self) {
                                Text(cost.formatted(.currency(code: "USD").precision(.significantDigits(2))))
                            }
                        }
                    }
                }
                .frame(height: 180)
            }
        }
    }

    // MARK: - Breakdown

    private var breakdownRows: [UsageAggregation.CategoryRow] {
        let rows = switch breakdownDimension {
        case .model:
            UsageAggregation.totals(events: rangeEvents) { $0.model }
        case .project:
            UsageAggregation.totals(events: rangeEvents, nilLabel: "No project") {
                $0.project.map { URL(filePath: $0).lastPathComponent }
            }
        }
        return Array(rows.prefix(8))
    }

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Breakdown")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Picker("Breakdown", selection: $breakdownDimension) {
                    ForEach(BreakdownDimension.allCases, id: \.self) { dimension in
                        Text(dimension.rawValue).tag(dimension)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
            Chart(breakdownRows) { row in
                BarMark(
                    x: .value("Tokens", row.tokens),
                    y: .value("Category", row.key)
                )
                .annotation(position: .trailing, alignment: .leading) {
                    Text(row.tokens.formatted(.number.notation(.compactName)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let tokens = value.as(Int.self) {
                            Text(tokens.formatted(.number.notation(.compactName)))
                        }
                    }
                }
            }
            .frame(height: max(120, CGFloat(breakdownRows.count) * 28))
        }
    }

    // MARK: - Empty / footer

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No usage in this period")
                .font(.title3)
            Text("Pick another period, or use Claude Code and watch it appear here.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footerNote: some View {
        var text = "Token counts are reconstructed from local Claude Code logs; costs come from your user-maintained pricing table. Both are estimates — not billing data, not your subscription quota."
        if !rangeCosts.unpricedModels.isEmpty {
            text += " Unpriced models excluded from costs: \(rangeCosts.unpricedModels.sorted().joined(separator: ", ")) (add prices in Settings → Pricing)."
        }
        return Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    DetailsWindowView()
        .environment(AppModel())
}
