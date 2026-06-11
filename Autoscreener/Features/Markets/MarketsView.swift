import SwiftUI

/// Sidebar "Markets" screen: the top-down regime read sits as a banner atop the
/// instruments it's derived from. Tapping the banner pushes the full factor
/// breakdown (`RegimeBreakdownView`); below it, browse the composite, indices,
/// and IDX-IC sectors — tapping one pushes its OHLCV candlestick chart. Owns its
/// own navigation, like `WatchlistView`. Mirrors the `NavigationStack` +
/// `.navigationDestination` pattern in `ScreenerView`.
///
/// The "Commodities" and "Currencies" sections instead show a live price +
/// % change snapshot (from `emitten/{symbol}/info` via `CommoditiesViewModel`),
/// loaded on appear and refreshable by pull-to-refresh. Those rows have no
/// historical chart data, so they don't navigate to a detail screen.
struct MarketsView: View {
    private let chartService: any ChartServicing
    @State private var regime: RegimeViewModel
    @State private var commodities: CommoditiesViewModel

    @MainActor
    init(chartService: any ChartServicing = AppDependencies.shared.chartService,
         regime: RegimeViewModel? = nil,
         commodities: CommoditiesViewModel? = nil) {
        self.chartService = chartService
        _regime = State(initialValue: regime ?? RegimeViewModel())
        _commodities = State(initialValue: commodities ?? CommoditiesViewModel())
    }

    var body: some View {
        NavigationStack {
            List {
                Section { regimeBanner }
                ForEach(MarketCatalog.grouped(), id: \.0) { group, symbols in
                    Section(group.rawValue) {
                        ForEach(symbols) { item in
                            // Commodities and currencies have no historical chart
                            // data, so they render as plain, non-navigating rows.
                            if item.group.hasChart {
                                NavigationLink(value: item) {
                                    row(item)
                                }
                            } else {
                                row(item)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Markets")
            .navigationDestination(for: MarketSymbol.self) { item in
                OHLCVChartView(vm: OHLCVChartViewModel(
                    symbol: item.symbol,
                    name: item.name,
                    service: chartService))
            }
            // Load both concurrently so the regime's breadth fan-out (one chart
            // request per LQ45 constituent) doesn't block the commodity prices.
            .task {
                async let r: () = regime.load()
                async let c: () = commodities.load()
                _ = await (r, c)
            }
            .refreshable {
                async let r: () = regime.load(force: true)
                async let c: () = commodities.load(force: true)
                _ = await (r, c)
            }
        }
        .accessibilityIdentifier("MarketsView")
    }

    // MARK: - Regime banner

    /// Compact regime summary at the top of the list. When a read exists it's a
    /// `NavigationLink` to the full breakdown; while the (slow) inputs load it
    /// shows a small spinner, and on total failure a quiet note — either way the
    /// markets list below stays usable and pull-to-refresh retries.
    @ViewBuilder
    private var regimeBanner: some View {
        if let read = regime.read {
            NavigationLink {
                RegimeBreakdownView(read: read)
            } label: {
                bannerLabel(read)
            }
            .accessibilityIdentifier("regime.banner")
        } else if regime.isLoading {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading the market…")
                    .foregroundStyle(.secondary)
            }
        } else if let error = regime.error {
            Text(error)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func bannerLabel(_ read: RegimeRead) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Market Regime")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(read.stance.rawValue)
                    .font(.headline)
                    .foregroundStyle(RegimeColors.color(read.stance))
                    .accessibilityIdentifier("regime.banner.stance")
            }
            Text(read.stance.guidance)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func row(_ item: MarketSymbol) -> some View {
        switch item.group {
        case .commodity, .currency:
            pricedRow(item)
        default:
            plainRow(item)
        }
    }

    private func plainRow(_ item: MarketSymbol) -> some View {
        HStack(spacing: 10) {
            Text(item.symbol)
                .font(.body.weight(.medium))
                .monospaced()
                .frame(minWidth: 96, alignment: .leading)
            Text(item.name)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func pricedRow(_ item: MarketSymbol) -> some View {
        let quote = commodities.quotes[item.symbol]
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
            } else if commodities.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("MarketsPricedRow.\(item.symbol)")
    }

    /// "+1.96%" / "-1.02%" with a fixed two decimals and an explicit sign.
    static func percentLabel(_ pct: Double) -> String {
        let sign = pct >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", pct))%"
    }
}
