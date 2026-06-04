import SwiftUI

/// Sidebar "Markets" screen: browse the composite, indices, and IDX-IC sectors;
/// tapping one pushes its OHLCV candlestick chart. Owns its own navigation, like
/// `WatchlistView`. Mirrors the `NavigationStack` + `.navigationDestination`
/// pattern in `ScreenerView`.
///
/// The "Commodities" and "Currencies" sections instead show a live price +
/// % change snapshot (from `emitten/{symbol}/info` via `CommoditiesViewModel`),
/// loaded on appear and refreshable by pull-to-refresh. Those rows have no
/// historical chart data, so they don't navigate to a detail screen.
struct MarketsView: View {
    private let chartService: any ChartServicing
    @State private var commodities: CommoditiesViewModel

    @MainActor
    init(chartService: any ChartServicing = AppDependencies.shared.chartService,
         commodities: CommoditiesViewModel? = nil) {
        self.chartService = chartService
        _commodities = State(initialValue: commodities ?? CommoditiesViewModel())
    }

    var body: some View {
        NavigationStack {
            List {
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
            .task { await commodities.load() }
            .refreshable { await commodities.load(force: true) }
        }
        .accessibilityIdentifier("MarketsView")
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
