import SwiftUI

/// Sidebar "Markets" dashboard: the top-down regime read renders beside the
/// instruments it's derived from (no longer a pushed detail page), laid out in
/// three two-column rows — regime + Global on the first row; Composite over
/// Indices on the left with the IDX-IC Sectors beside them on the second row;
/// Commodities and Currencies in a row below. Owns its own navigation, like `WatchlistView`;
/// tapping a chartable row pushes its OHLCV candlestick chart via the same
/// value-based `.navigationDestination` pattern as `ScreenerView`.
///
/// Every row shows a live price + % change snapshot (from `emitten/{symbol}/info`
/// via `MarketQuotesViewModel`), loaded on appear and refreshable by
/// pull-to-refresh. Only the composite and headline indices tap through to their
/// chart; global indices and the IDX-IC sectors stay snapshot-only on the
/// dashboard (as do commodities and currencies, which have no chart history).
struct MarketsView: View {
    private let chartService: any ChartServicing
    @State private var regime: RegimeViewModel
    @State private var marketQuotes: MarketQuotesViewModel

    @MainActor
    init(chartService: any ChartServicing = AppDependencies.shared.chartService,
         regime: RegimeViewModel? = nil,
         quotes: MarketQuotesViewModel? = nil) {
        self.chartService = chartService
        _regime = State(initialValue: regime ?? RegimeViewModel())
        _marketQuotes = State(initialValue: quotes ?? MarketQuotesViewModel())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 16) {
                        regimeSection
                        MarketSectionCard(group: .global, symbols: symbols(.global), quotes: marketQuotes)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 16) {
                            MarketSectionCard(group: .composite, symbols: symbols(.composite), quotes: marketQuotes)
                            MarketSectionCard(group: .index, symbols: symbols(.index), quotes: marketQuotes)
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                        VStack(spacing: 16) {
                            MarketSectionCard(group: .commodity, symbols: symbols(.commodity), quotes: marketQuotes)
                            MarketSectionCard(group: .currency, symbols: symbols(.currency), quotes: marketQuotes)
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    // Sectors is the longest IDX group; it gets its own full-width row
                    // as a single column rather than sharing a two-column row.
                    MarketSectionCard(group: .sector, symbols: symbols(.sector), quotes: marketQuotes)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Markets")
            // Cold launch with no cache: the static dashboard scaffold stays mounted (so
            // `.task` keeps running) while a centered spinner covers it until the first
            // sweep prices a row or the regime read lands.
            .overlay {
                if marketQuotes.loadState == .loading && regime.read == nil {
                    marketsLoadingView
                }
            }
            .navigationDestination(for: MarketSymbol.self) { item in
                OHLCVChartView(vm: OHLCVChartViewModel(
                    symbol: item.symbol,
                    name: item.name,
                    service: chartService))
            }
            // Load both concurrently so the regime's breadth fan-out (one chart
            // request per LQ45 constituent) doesn't block the market prices.
            .task {
                async let r: () = regime.load()
                async let q: () = marketQuotes.load()
                _ = await (r, q)
            }
            .refreshable {
                async let r: () = regime.load(force: true)
                async let q: () = marketQuotes.load(force: true)
                _ = await (r, q)
            }
        }
        .accessibilityIdentifier("MarketsView")
    }

    private func symbols(_ group: MarketGroup) -> [MarketSymbol] {
        MarketCatalog.all.filter { $0.group == group }
    }

    // MARK: - Regime (inline)

    /// The full top-down regime breakdown sits at the top of the dashboard. Before the
    /// first read lands it shows a small spinner; the regime only computes while the IDX
    /// session is open, so a completed sweep outside the session shows a short note
    /// instead of vanishing. Pull-to-refresh recomputes the read either way.
    @ViewBuilder
    private var regimeSection: some View {
        switch regime.loadState {
        case .ready:
            if let read = regime.read {
                RegimeBreakdownContent(read: read)
                    .frame(maxWidth: 720, alignment: .leading)
                    // Fill this HStack cell (not the whole row) so Global sits beside it.
                    .frame(maxWidth: .infinity, alignment: .top)
                    .accessibilityIdentifier("regime.section")
            }
        case .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading the market…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("regime.loading")
        case .empty, .failed:
            Text("Regime updates while the market is open")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("regime.empty")
        }
    }

    /// Centered cold-launch placeholder for the whole dashboard, shown until the first
    /// sweep prices a row or the regime read lands.
    private var marketsLoadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading markets…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("markets.loading")
    }
}

/// One market group rendered as a titled dashboard tile: a header plus its priced
/// rows. Navigating groups (`group.navigatesToDetail` — the composite and headline
/// indices) wrap each row in a `NavigationLink` so it pushes the OHLCV chart; global
/// indices, sectors, commodities, and currencies render as plain rows.
/// `columns > 1` lays the rows out in a fixed grid (used by the long Sectors group);
/// the grid is deliberately non-lazy so every row stays in the view hierarchy even
/// when scrolled out of view — UI tests query rows by identifier regardless of the
/// scroll position.
struct MarketSectionCard: View {
    let group: MarketGroup
    let symbols: [MarketSymbol]
    let quotes: MarketQuotesViewModel
    var columns: Int = 1

    /// `symbols` chunked into rows of `columns` for the fixed grid layout.
    private var gridRows: [[MarketSymbol]] {
        guard columns > 1 else { return symbols.map { [$0] } }
        return stride(from: 0, to: symbols.count, by: columns).map {
            Array(symbols[$0 ..< min($0 + columns, symbols.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.rawValue)
                .font(.headline)
            VStack(spacing: 4) {
                ForEach(Array(gridRows.enumerated()), id: \.offset) { _, rowItems in
                    HStack(spacing: 12) {
                        ForEach(rowItems) { item in
                            rowOrLink(item).frame(maxWidth: .infinity)
                        }
                        // Pad an incomplete trailing row so columns stay aligned.
                        if rowItems.count < columns {
                            ForEach(0 ..< (columns - rowItems.count), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("MarketSectionCard.\(group.rawValue)")
    }

    /// Only the composite and headline indices push a chart; global indices and the
    /// IDX-IC sectors stay snapshot-only on the dashboard (as do commodities and
    /// currencies, which have no chart at all), so they render as plain rows.
    @ViewBuilder
    private func rowOrLink(_ item: MarketSymbol) -> some View {
        if item.group.navigatesToDetail {
            NavigationLink(value: item) {
                pricedRow(item)
            }
            .buttonStyle(.plain)
        } else {
            pricedRow(item)
        }
    }

    private func pricedRow(_ item: MarketSymbol) -> some View {
        let quote = quotes.quotes[item.symbol]
        return HStack(spacing: 10) {
            Text(item.symbol)
                .font(.body.weight(.medium))
                .monospaced()
                .frame(minWidth: 96, alignment: .leading)
            Text(quote?.name ?? item.name)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let quote {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(quote.formattedPrice)
                        .font(.body.weight(.medium))
                        .monospacedDigit()
                    if let pct = quote.changePercent {
                        Text(Self.percentLabel(pct))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(quote.isUp ? .green : .red)
                    }
                }
            } else if !quotes.hasLoadedOnce {
                ProgressView().controlSize(.small)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityIdentifier("MarketsPricedRow.\(item.symbol)")
    }

    /// "+1.96%" / "-1.02%" with a fixed two decimals and an explicit sign.
    static func percentLabel(_ pct: Double) -> String {
        let sign = pct >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", pct))%"
    }
}
