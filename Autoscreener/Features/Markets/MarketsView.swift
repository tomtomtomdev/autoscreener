import SwiftUI

/// Sidebar "Markets" screen: browse the composite, indices, and IDX-IC sectors;
/// tapping one pushes its OHLCV candlestick chart. Owns its own navigation, like
/// `WatchlistView`. Mirrors the `NavigationStack` + `.navigationDestination`
/// pattern in `ScreenerView`.
struct MarketsView: View {
    private let chartService: any ChartServicing

    init(chartService: any ChartServicing = AppDependencies.shared.chartService) {
        self.chartService = chartService
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(MarketCatalog.grouped(), id: \.0) { group, symbols in
                    Section(group.rawValue) {
                        ForEach(symbols) { item in
                            NavigationLink(value: item) {
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
        }
        .accessibilityIdentifier("MarketsView")
    }

    private func row(_ item: MarketSymbol) -> some View {
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
}
