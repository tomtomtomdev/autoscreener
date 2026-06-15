import SwiftUI

/// The paper-trading screen: a 100M IDR simulated portfolio that allocates across the
/// watchlist, sized by the market regime. The user *generates* a proposed rebalance
/// (regime → exposure, conviction → weights, capped), reviews the per-line rationale,
/// then *executes* it. Holdings + P&L track over time. Nothing here is a real order.
struct PaperTradingView: View {
    @State var vm: PaperTradingViewModel
    let title: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summaryHeader
                Divider()
                planSection
                if vm.hasPositions {
                    Divider()
                    holdingsSection
                }
                if !vm.trades.isEmpty {
                    Divider()
                    tradeLogSection
                }
                disclaimer
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(title)
        .accessibilityIdentifier("PaperTradingView")
        .toolbar {
            ToolbarItemGroup {
                Button("Generate plan") { vm.generatePlan() }
                    .disabled(!vm.canPlan)
                    .accessibilityIdentifier("PaperTradingGenerateButton")
                Button(role: .destructive) { vm.reset() } label: { Text("Reset") }
                    .accessibilityIdentifier("PaperTradingResetButton")
            }
        }
        .task { await vm.autoRunIfNeeded() }
    }

    // MARK: - Header

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(Self.idr(vm.equity))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .accessibilityIdentifier("PaperTradingEquity")
                returnBadge
                Spacer()
                regimeBadge
            }
            HStack(spacing: 28) {
                stat("Cash", Self.idr(vm.cash), sub: Self.pct(vm.cashWeight) + " of equity")
                stat("Invested", Self.idr(vm.investedValue), sub: nil)
                stat("Unrealized P&L", Self.signedIdr(vm.unrealizedPnL),
                     sub: nil, tint: tint(vm.unrealizedPnL))
                stat("Realized P&L", Self.signedIdr(vm.realizedPnL),
                     sub: nil, tint: tint(vm.realizedPnL))
            }
        }
    }

    private var returnBadge: some View {
        Text(Self.signedPct(vm.totalReturnPct))
            .font(.headline)
            .foregroundStyle(tint(vm.totalReturnPct))
            .accessibilityIdentifier("PaperTradingTotalReturn")
    }

    @ViewBuilder private var regimeBadge: some View {
        if let regime = vm.regime {
            VStack(alignment: .trailing, spacing: 2) {
                Text(regime.stance.rawValue)
                    .font(.headline)
                    .foregroundStyle(RegimeColors.color(regime.stance))
                Text("target \(Self.pct(targetExposure(for: regime)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("PaperTradingRegimeBadge")
        } else {
            Text("Regime —").font(.headline).foregroundStyle(.secondary)
                .accessibilityIdentifier("PaperTradingRegimeBadge")
        }
    }

    private func stat(_ label: String, _ value: String, sub: String?, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(tint ?? .primary)
            if let sub { Text(sub).font(.caption2).foregroundStyle(.tertiary) }
        }
    }

    // MARK: - Proposed plan

    @ViewBuilder private var planSection: some View {
        if let plan = vm.pendingPlan {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Proposed rebalance").font(.title3.weight(.semibold))
                    Spacer()
                    Button("Execute") { vm.execute() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!plan.hasTrades)
                        .accessibilityIdentifier("PaperTradingExecuteButton")
                }
                Text("\(plan.stance.rawValue) · deploy \(Self.pct(plan.targetExposure)) of equity · "
                     + "\(plan.lines.count) order\(plan.lines.count == 1 ? "" : "s")")
                    .font(.subheadline).foregroundStyle(.secondary)

                if plan.lines.isEmpty {
                    Text("Already aligned with the target — no trades.")
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("PaperTradingPlanEmpty")
                } else {
                    ForEach(plan.lines) { line in planRow(line) }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("No proposed plan").font(.title3.weight(.semibold))
                Text(vm.canPlan
                     ? "Generate a regime-weighted allocation from your watchlist."
                     : "Waiting for the watchlist and prices to load…")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("PaperTradingNoPlan")
        }
    }

    private func planRow(_ line: AllocationLine) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(line.side == .buy ? "BUY" : "SELL")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(line.side == .buy ? .green : .red)
                    .frame(width: 42, alignment: .leading)
                Text(line.symbol).font(.body.weight(.semibold))
                Spacer()
                Text("\(Self.shares(abs(line.deltaShares))) sh").foregroundStyle(.secondary)
                Text(Self.idr(line.estValue)).frame(minWidth: 90, alignment: .trailing)
                Text(Self.pct(line.targetWeight)).foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            .font(.system(.body, design: .rounded))
            Text(line.rationale).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("PaperTradingPlanRow_\(line.symbol)")
    }

    // MARK: - Holdings

    private var holdingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Holdings").font(.title3.weight(.semibold))
            ForEach(vm.holdings) { h in holdingRow(h) }
        }
    }

    private func holdingRow(_ h: HoldingRow) -> some View {
        let detail = "avg \(Self.idr(h.avgCost)) · last \(Self.idr(h.last))"
        return HStack {
            Text(h.symbol).font(.body.weight(.semibold)).frame(width: 70, alignment: .leading)
            Text("\(Self.shares(h.shares)) sh").foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(Self.idr(h.marketValue))
                Text(detail).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(Self.signedPct(h.unrealizedPct))
                .foregroundStyle(tint(h.unrealizedPnL))
                .frame(width: 72, alignment: .trailing)
        }
        .font(.system(.body, design: .rounded))
        .accessibilityIdentifier("PaperTradingHoldingRow_\(h.symbol)")
    }

    // MARK: - Trade log

    private var tradeLogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trade log").font(.title3.weight(.semibold))
            ForEach(vm.trades) { t in tradeRow(t) }
        }
    }

    private func tradeRow(_ t: PaperTrade) -> some View {
        let fill = "\(Self.shares(t.shares)) @ \(Self.idr(t.price))"
        let when = t.date.formatted(date: .abbreviated, time: .shortened)
        return HStack {
            Text(t.side == .buy ? "BUY" : "SELL")
                .font(.caption.weight(.bold))
                .foregroundStyle(t.side == .buy ? Color.green : Color.red)
                .frame(width: 42, alignment: .leading)
            Text(t.symbol).frame(width: 70, alignment: .leading)
            Text(fill).foregroundStyle(.secondary)
            Spacer()
            if let pnl = t.realizedPnL {
                Text(Self.signedIdr(pnl)).foregroundStyle(tint(pnl))
            }
            Text(when).font(.caption2).foregroundStyle(.tertiary)
        }
        .font(.system(.callout, design: .rounded))
    }

    private var disclaimer: some View {
        Text("Paper trading — a simulation seeded with Rp 100,000,000. No real orders are placed.")
            .font(.caption2).foregroundStyle(.tertiary).padding(.top, 4)
    }

    // MARK: - Helpers

    private func tint(_ value: Double) -> Color { value > 0 ? .green : (value < 0 ? .red : .secondary) }

    private func targetExposure(for regime: RegimeRead) -> Double {
        AllocationConfig.standard.exposure(forScore: regime.score)
    }

    // Compact IDR / share / percent formatters (no Foundation currency dependency).

    static func idr(_ value: Double) -> String { "Rp " + compact(value) }
    static func signedIdr(_ value: Double) -> String {
        (value >= 0 ? "+Rp " : "−Rp ") + compact(abs(value))
    }
    static func compact(_ value: Double) -> String {
        let a = abs(value)
        switch a {
        case 1_000_000_000...: return String(format: "%.2fB", value / 1_000_000_000)
        case 1_000_000...:     return String(format: "%.1fM", value / 1_000_000)
        case 1_000...:         return String(format: "%.0fK", value / 1_000)
        default:               return String(format: "%.0f", value)
        }
    }
    static func shares(_ value: Double) -> String {
        String(format: "%.0f", value)
    }
    static func pct(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
    static func signedPct(_ value: Double) -> String { String(format: "%+.1f%%", value * 100) }
}
