import SwiftUI

/// Sidebar "Positions to Review" screen: the user-facing surface over the Gate-5 exit discipline
/// (`PositionReviewer`). Renders each held name's hold / trim / exit verdict as a card showing the
/// action, the one-line reason, and the engine's full reviewed reasoning (gates, governance,
/// thesis-vs-entry, MoS-vs-exit-floor) tucked behind an expandable rationale.
///
/// Framed as a discipline, not an order: it shows what the sell-side rules would do and why, leaving the
/// decision to the reader. The buy-side mirror is `TodaysPicksView`.
struct PositionsReviewView: View {
    @State private var vm: PositionReviewViewModel

    @MainActor
    init(vm: PositionReviewViewModel? = nil) {
        _vm = State(initialValue: vm ?? PositionReviewViewModel())
    }

    var body: some View {
        Group {
            if !vm.decisions.isEmpty {
                decisionsList
            } else if vm.isLoading {
                ProgressView("Reviewing positions…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vm.error {
                ContentUnavailableView("Review unavailable", systemImage: "stethoscope",
                                       description: Text(error))
            } else if vm.hasLoaded {
                ContentUnavailableView("No positions to review",
                                       systemImage: "checkmark.seal",
                                       description: Text("There are no open paper positions, or every holding's thesis is intact under the current data. Doing nothing when nothing has broken is itself the discipline."))
                    .accessibilityIdentifier("positionsreview.empty")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Positions to Review")
        .task { await vm.load() }
        // No manual refresh: re-review holdings when a fresh global sweep lands, so dropping
        // the pull-to-refresh control never strands a stale verdict (Decision 2 in UI-CHROME-PLAN).
        .onChange(of: AppDependencies.shared.marketDataStore.lastSweepAt) { _, _ in
            Task { await vm.load(force: true) }
        }
        .accessibilityIdentifier("PositionsReviewView")
    }

    private var decisionsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summary
                // Exits/trims first so the names that need action lead; holds follow.
                ForEach(sortedDecisions, id: \.ticker) { decision in
                    decisionCard(decision)
                }
                footnote
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// Actionable (exit/trim) names first, then holds; stable by ticker within each group.
    private var sortedDecisions: [ExitDecision] {
        vm.decisions.sorted { lhs, rhs in
            if (lhs.action == .hold) != (rhs.action == .hold) { return rhs.action == .hold }
            return lhs.ticker < rhs.ticker
        }
    }

    private var summary: some View {
        let act = vm.actionable.count
        let total = vm.decisions.count
        return Text(act == 0 ? "\(total) reviewed · all hold" : "\(total) reviewed · \(act) to act on")
            .font(.headline)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("positionsreview.summary")
    }

    // MARK: - Decision card

    private func decisionCard(_ d: ExitDecision) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(d.ticker)
                    .font(.title3.bold())
                Spacer(minLength: 0)
                actionBadge(d.action)
            }
            Text(d.reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            rationale(d)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("positionsreview.row.\(d.ticker)")
    }

    private func actionBadge(_ action: ExitAction) -> some View {
        let (label, color) = Self.style(action)
        return Text(label)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .accessibilityIdentifier("positionsreview.action.\(action.rawValue)")
    }

    private static func style(_ action: ExitAction) -> (String, Color) {
        switch action {
        case .hold: return ("HOLD", .secondary)
        case .trim: return ("TRIM", .orange)
        case .exit: return ("EXIT", .red)
        }
    }

    private func rationale(_ d: ExitDecision) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(d.audit.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 6)
            .accessibilityIdentifier("positionsreview.audit.\(d.ticker)")
        } label: {
            Text("Why")
                .font(.callout.weight(.medium))
        }
        .accessibilityIdentifier("positionsreview.why.\(d.ticker)")
    }

    private var footnote: some View {
        Text("Sell-side discipline (Gate 5): a name is flagged to EXIT only on a broken thesis, a failed hard gate, a governance breach, or a price that has run well past its re-computed intrinsic value — never on a drawdown or a temporary dip. The rationale shows every check behind each verdict.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
