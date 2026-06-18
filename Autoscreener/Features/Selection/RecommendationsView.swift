import SwiftUI

/// Presentation helpers shared by the unified Recommendations rows — formatting, the trailing action
/// badge, and the Gate-2/Gate-3 chips parsed from a buy pick's audit. Kept here (pure, UI-light, and
/// independent of the engine models) so the row can render both a buy `Recommendation` and a sell
/// `ExitDecision`, and so the chip parsing stays directly unit-testable.
enum RecommendationFormatting {
    /// A `Ratio` (fraction) as a whole-percent string, matching the engine's own audit convention.
    static func pct(_ ratio: Double) -> String { String(format: "%.0f%%", ratio * 100) }

    /// An intrinsic value as a grouped, whole-rupiah string (e.g. 6_364 → "6,364").
    static func amount(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? String(Int(value))
    }

    // MARK: - Action badge (the trailing chip on every row)

    /// The label, accessibility key, and colour for a row's action chip. Buys read "BUY"; verdicts read
    /// their hold/trim/exit action — so a single list shows both sides of the discipline at a glance.
    static func actionStyle(_ row: ActionRow) -> (label: String, key: String, color: Color) {
        switch row {
        case .buy:
            return ("BUY", "buy", .green)
        case .verdict(let d):
            switch d.action {
            case .hold: return ("HOLD", "hold", .secondary)
            case .trim: return ("TRIM", "trim", .orange)
            case .exit: return ("EXIT", "exit", .red)
            }
        }
    }

    // MARK: - Gate chips (Gate-2 governance / Gate-3 consensus), parsed from a buy pick's audit

    /// A labelled chip derived from a `Recommendation`'s audit lines. `kind` drives the colour.
    struct GateBadge: Equatable {
        enum Kind { case governance, consensus }
        let kind: Kind
        let label: String

        var color: Color {
            switch kind {
            case .governance: return .green
            case .consensus:  return .orange
            }
        }
    }

    /// Reads the engine's audit trail for the Gate-2 / Gate-3 lines and turns them into chips. Pure and
    /// independent of SwiftUI (returns plain data), so it is unit-tested directly:
    ///   • `"governance OK […]"`  ⇒ a green "Governance ✓" chip (a survivor passed the Gate-2 veto).
    ///   • `"consensus ±x% […]"`  ⇒ an amber "Consensus fade ±x%" chip (Gate-3 faded the sell-side crowd).
    static func gateBadges(_ audit: [String]) -> [GateBadge] {
        var badges: [GateBadge] = []
        if audit.contains(where: { $0.hasPrefix("governance OK") }) {
            badges.append(GateBadge(kind: .governance, label: "Governance ✓"))
        }
        if let line = audit.first(where: { $0.hasPrefix("consensus ") }) {
            let tilt = line.dropFirst("consensus ".count).prefix { $0 != " " }
            badges.append(GateBadge(kind: .consensus, label: "Consensus fade \(tilt)"))
        }
        return badges
    }
}

/// The unified home screen: the Tier-A action inbox **stacked above the composite Watchlist** in one
/// scroll. The top merges the buy-side picks (the selection engine, §8) and the Gate-5 sell-side review
/// (`PositionReviewer`) into one ranked list — the answer to *"what should I do today?"* (exits lead,
/// then trims, then fresh buys, then holds; each row carries its action badge, a reason or conviction
/// metrics, and the engine's full reasoning behind an expandable "Why"). Beneath it, the upstream radar:
/// the composite Watchlist the screener sweep feeds (`WatchlistSection`).
///
/// Framed as a discipline, not an order: it shows what the rules would do and why, leaving the judgement
/// to the reader. Pure view composition — it owns the recommendations VM and is *handed* the watchlist VM
/// (both unchanged), so each side's data path and stores are untouched.
struct RecommendationsView: View {
    @State private var vm: RecommendationsViewModel
    /// Handed in (owned by `MainSidebarView`) so the search field can bind its `searchText`; the
    /// watchlist section reads its other outputs through Observation.
    @Bindable private var watchlist: WatchlistViewModel
    /// Set when a watchlist row's stock code is tapped — drives the push to `StockDetailView`.
    @State private var selectedTicker: StockTicker?
    /// Set when a watchlist row's screener icon is tapped — drives the push to that screener's list.
    @State private var selectedScreener: BandarScreenerKind?
    /// Live width of the recommendations grid, fed by a background `GeometryReader`; drives the
    /// one-vs-two-column choice in `gridColumns`.
    @State private var availableWidth: CGFloat = 0

    @MainActor
    init(vm: RecommendationsViewModel? = nil, watchlist: WatchlistViewModel) {
        _vm = State(initialValue: vm ?? RecommendationsViewModel())
        self.watchlist = watchlist
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                recommendationsSection
                Divider()
                WatchlistSection(vm: watchlist,
                                 onSelect: { selectedTicker = $0 },
                                 onSelectScreener: { selectedScreener = $0 })
            }
            .padding(24)
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 760, minHeight: 560)
        .navigationTitle("Recommendations")
        // Search scopes to the watchlist section (recommendation cards always stay visible).
        .searchable(text: $watchlist.searchText, placement: .toolbar, prompt: "Search stock code")
        .task {
            await vm.load()
            await watchlist.autoRunIfNeeded()
        }
        // No manual refresh: re-run the buy/sell sides when a fresh global sweep lands, so dropping the
        // pull-to-refresh control never strands a stale row (Decision 2 in UI-CHROME-PLAN). The watchlist
        // section re-projects automatically off the store's version.
        .onChange(of: AppDependencies.shared.marketDataStore.lastSweepAt) { _, _ in
            Task { await vm.load(force: true) }
        }
        // `lastSweepAt` above is stamped after the regime leg but BEFORE the per-symbol cache-warming
        // phase, so on a cold cache that reload sees nothing and shows "waiting". Reload again the
        // instant warming FINISHES (isWarming true→false) — the cache is warm now, so the screen flips
        // from "waiting" to the ranked picks without needing a tab switch.
        .onChange(of: AppDependencies.shared.dataSweepCoordinator.isWarming) { _, warming in
            if !warming { Task { await vm.load(force: true) } }
        }
        .navigationDestination(item: $selectedTicker) { ticker in
            StockDetailView(ticker: ticker)
        }
        // Tapping a row's screener icon drills into that screener's full results list. A freshly built
        // ScreenerViewModel is fine — it's a thin projection over the shared store, so cached rows render
        // immediately (same construction as MainSidebarView's per-screener VMs).
        .navigationDestination(item: $selectedScreener) { kind in
            let deps = AppDependencies.shared
            ScreenerView(
                vm: ScreenerViewModel(store: deps.screenerStore,
                                      coordinator: deps.dataSweepCoordinator,
                                      kind: kind),
                title: kind.displayName)
        }
        .accessibilityIdentifier("RecommendationsView")
    }

    /// Two flexible columns once there's room for a pair of ~340pt cards plus spacing, one below that
    /// (and before the first layout pass, when width is still 0). Top-aligned so uneven-height cards in
    /// a row line up at the top.
    private var gridColumns: [GridItem] {
        let twoUp = availableWidth >= 700
        return Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top),
                     count: twoUp ? 2 : 1)
    }

    /// The action inbox at the top of the screen. While the market is closed it ranks the last-warmed
    /// close, so a caption above the inbox stamps it "as of <date> · market closed" (nil/absent while open).
    private var recommendationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let asOf = vm.asOf { asOfCaption(asOf) }
            recommendationsBody
        }
    }

    /// "Figures as of <date> · market closed" — shown only when the inbox is ranking the last-warmed
    /// close (i.e. the market is closed and the cache has been warmed at least once).
    private func asOfCaption(_ date: Date) -> some View {
        Label("Figures as of \(date.formatted(date: .abbreviated, time: .omitted)) · market closed",
              systemImage: "moon.zzz")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("recommendations.asOfClose")
    }

    /// Renders compactly in its non-list states (loading / error / nothing-to-do) so the watchlist
    /// section below always stays in view.
    @ViewBuilder
    private var recommendationsBody: some View {
        if !vm.rows.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                summary
                // Cards go two-up when the window is wide enough, collapsing to one column when narrow.
                // `.flexible()` with a width-driven count (not `.adaptive`) caps the grid at two columns
                // on a maximized window. Summary / skipped / footnote stay full-width above and below.
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 16) {
                    ForEach(vm.rows) { row in
                        ActionRowView(row: row)
                    }
                }
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: WidthKey.self, value: proxy.size.width)
                })
                .onPreferenceChange(WidthKey.self) { availableWidth = $0 }
                skippedNote
                footnote
            }
        } else if vm.isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Sizing today's actions…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let error = vm.error {
            ContentUnavailableView("Recommendations unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if vm.awaitingData {
            // Cache still cold: the engine ranks from the sweep-filled cache, which hasn't been warmed
            // yet (e.g. a fresh launch, or the first sweep after market open). Honest "waiting" rather
            // than a misleading "nothing to act on". The sweep refills it; revisiting the tab retries.
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for the data sweep to gather today's figures…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("recommendations.awaitingData")
        } else if vm.hasLoaded {
            VStack(alignment: .leading, spacing: 12) {
                Label("Nothing to act on today — nothing in the watchlist clears the engine's gates and margin of safety under the current regime, and every holding's thesis is intact. Being patient when there's nothing to do is itself a discipline.",
                      systemImage: "checkmark.seal")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("recommendations.empty")
                skippedNote
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// Non-blocking note for names the engine/reviewer could not value (missing fundamentals / no
    /// price) and skipped this run, so one bad ticker reads as "N skipped" rather than emptying the
    /// screen with an error. Renders nothing when there were no skips. The per-name reasons are
    /// available on hover (`.help`).
    @ViewBuilder
    private var skippedNote: some View {
        if !vm.skipped.isEmpty {
            Label("\(vm.skipped.count) name\(vm.skipped.count == 1 ? "" : "s") skipped — missing fundamentals or price data.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(vm.skipped.map { "\($0.ticker): \($0.reason)" }.joined(separator: "\n"))
                .accessibilityIdentifier("recommendations.skipped")
        }
    }

    private var summary: some View {
        let act = vm.actionableCount
        let total = vm.rows.count
        return Text(act == 0 ? "\(total) reviewed · nothing to act on" : "\(total) items · \(act) to act on")
            .font(.headline)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("recommendations.summary")
    }

    private var footnote: some View {
        Text("One ranked list: buy-side candidates the engine would size (suggestions, not orders) and the Gate-5 sell-side discipline for names you hold — flagged to EXIT only on a broken thesis, a failed hard gate, a governance breach, or a price run well past intrinsic value, never on a dip. Each row's “Why” shows the full reasoning.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One card in the unified inbox. Shares the chrome (ticker title, trailing action badge, rounded
/// background, expandable "Why" audit) across both kinds and switches only the middle block: a buy
/// shows its sizing metrics and gate chips; a verdict shows its one-line reason.
struct ActionRowView: View {
    let row: ActionRow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            rationale
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("recommendations.row.\(row.ticker)")
    }

    private var header: some View {
        let style = RecommendationFormatting.actionStyle(row)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(row.ticker)
                .font(.title3.bold())
            Spacer(minLength: 0)
            Text(style.label)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(style.color.opacity(0.15), in: Capsule())
                .foregroundStyle(style.color)
                .accessibilityIdentifier("recommendations.action.\(style.key)")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch row {
        case .buy(let r):
            HStack(alignment: .top, spacing: 24) {
                metric("Suggested weight", RecommendationFormatting.pct(r.suggestedWeight))
                metric("Conviction", RecommendationFormatting.pct(r.conviction))
                metric("Margin of safety", RecommendationFormatting.pct(r.marginOfSafety))
                metric("Intrinsic value", RecommendationFormatting.amount(r.intrinsicValue))
            }
            gateChips(r.audit)
        case .verdict(let d):
            Text(d.reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func gateChips(_ audit: [String]) -> some View {
        let badges = RecommendationFormatting.gateBadges(audit)
        if !badges.isEmpty {
            HStack(spacing: 6) {
                ForEach(badges, id: \.label) { badge in
                    Text(badge.label)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(badge.color.opacity(0.15), in: Capsule())
                        .foregroundStyle(badge.color)
                }
            }
            .accessibilityIdentifier("recommendations.gates.\(row.ticker)")
        }
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

    private var rationale: some View {
        let audit = row.audit
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(audit.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 6)
            .accessibilityIdentifier("recommendations.audit.\(row.ticker)")
        } label: {
            Text("Why")
                .font(.callout.weight(.medium))
        }
        .accessibilityIdentifier("recommendations.why.\(row.ticker)")
    }
}

/// Reports a view's measured width up the tree so `RecommendationsView` can pick one vs. two grid
/// columns. Carried by a background `GeometryReader` so reading the width never affects layout.
private struct WidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
