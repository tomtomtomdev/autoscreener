import SwiftUI

/// Sidebar "Today's Picks" screen: the user-facing surface over the Tier-A selection engine (§8).
/// Renders the ranked, audited `Recommendation`s — each as a card showing the suggested position
/// weight, conviction, margin of safety, and intrinsic value, with the engine's full reasoning
/// (gates, scorers, flow/timing modifiers, sizing) tucked behind an expandable rationale.
///
/// Framed as *candidates under a discipline*, never a guarantee: the screen surfaces what the engine
/// would size and why, leaving the judgement to the reader.
struct TodaysPicksView: View {
    @State private var vm: TodaysPicksViewModel

    @MainActor
    init(vm: TodaysPicksViewModel? = nil) {
        _vm = State(initialValue: vm ?? TodaysPicksViewModel())
    }

    var body: some View {
        NavigationStack {
            Group {
                if !vm.picks.isEmpty {
                    picksList
                } else if vm.isLoading {
                    ProgressView("Ranking today's picks…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = vm.error {
                    ContentUnavailableView("Picks unavailable", systemImage: "star.slash",
                                           description: Text(error))
                } else if vm.hasLoaded {
                    ContentUnavailableView("No picks today",
                                           systemImage: "tray",
                                           description: Text("Nothing in the watchlist clears the engine's gates and margin of safety under the current regime. Being patient when there's nothing to do is itself a discipline."))
                        .accessibilityIdentifier("todayspicks.empty")
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Today's Picks")
            .task { await vm.load() }
            .refreshable { await vm.load(force: true) }
        }
        .accessibilityIdentifier("TodaysPicksView")
    }

    private var picksList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summary
                ForEach(Array(vm.picks.enumerated()), id: \.element.ticker) { index, pick in
                    pickCard(index + 1, pick)
                }
                footnote
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var summary: some View {
        Text("\(vm.picks.count) \(vm.picks.count == 1 ? "pick" : "picks")")
            .font(.headline)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("todayspicks.summary")
    }

    // MARK: - Pick card

    private func pickCard(_ rank: Int, _ pick: Recommendation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(rank)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(pick.ticker)
                    .font(.title3.bold())
                Spacer(minLength: 0)
                Text("weight \(Self.pct(pick.suggestedWeight))")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.tint)
            }
            HStack(alignment: .top, spacing: 24) {
                metric("Conviction", Self.pct(pick.conviction))
                metric("Margin of safety", Self.pct(pick.marginOfSafety))
                metric("Intrinsic value", Self.amount(pick.intrinsicValue))
            }
            rationale(pick)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("todayspicks.row.\(pick.ticker)")
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.body.weight(.medium).monospacedDigit())
        }
    }

    private func rationale(_ pick: Recommendation) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(pick.audit.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 6)
            .accessibilityIdentifier("todayspicks.audit.\(pick.ticker)")
        } label: {
            Text("Why this pick")
                .font(.callout.weight(.medium))
        }
        .accessibilityIdentifier("todayspicks.why.\(pick.ticker)")
    }

    private var footnote: some View {
        Text("Candidates the engine would size under the chosen discipline — not a recommendation to buy. Weights are pre-liquidity-capped suggestions; the rationale shows every gate, score, and modifier that produced each pick.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Formatting (kept in the view; the engine models stay UI-free)

    /// A `Ratio` (fraction) as a whole-percent string, matching the engine's own audit convention.
    static func pct(_ ratio: Double) -> String { String(format: "%.0f%%", ratio * 100) }

    /// An intrinsic value as a grouped, whole-rupiah string (e.g. 6_364 → "6,364").
    static func amount(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? String(Int(value))
    }
}
