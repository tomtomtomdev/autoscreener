import SwiftUI
import Charts
import Observation

@MainActor
@Observable
final class OHLCVChartViewModel {
    let symbol: String
    let name: String
    var timeframe: ChartTimeframe = .oneYear

    private(set) var series: PriceSeries?
    var isLoading = false
    var error: String?

    private let service: any ChartServicing
    private var loadedTimeframe: ChartTimeframe?

    init(symbol: String, name: String, service: any ChartServicing) {
        self.symbol = symbol
        self.name = name
        self.service = service
    }

    func load(force: Bool = false) async {
        if !force, series != nil, loadedTimeframe == timeframe { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            series = try await service.candles(symbol: symbol, timeframe: timeframe, chartType: .candle)
            loadedTimeframe = timeframe
        } catch ChartError.unauthorized {
            series = nil
            error = "Session expired. Please sign in again."
        } catch ChartError.paywall {
            series = nil
            error = "Chart data isn't available on your plan."
        } catch ChartError.network(let detail) {
            series = nil
            error = "Couldn't load chart (\(detail))."
        } catch {
            series = nil
            self.error = "Couldn't load chart."
        }
    }
}

/// OHLCV candlestick + volume chart for one symbol. Shared by the Markets menu
/// and the Stock Detail "Chart" tab. Candlesticks via Swift Charts: a thin wick
/// (`RuleMark` low→high) plus a body (`RectangleMark` open→close), green when the
/// bar closed up, red when down; a dashed line marks the previous close.
struct OHLCVChartView: View {
    @Bindable var vm: OHLCVChartViewModel

    var body: some View {
        VStack(spacing: 0) {
            timeframePicker
            Divider()
            content
        }
        .accessibilityIdentifier("OHLCVChartView")
        .navigationTitle(vm.symbol)
        .task { await vm.load() }
        .onChange(of: vm.timeframe) { _, _ in Task { await vm.load(force: true) } }
    }

    private var timeframePicker: some View {
        HStack {
            Picker("Timeframe", selection: $vm.timeframe) {
                ForEach(ChartTimeframe.allCases, id: \.self) { tf in
                    Text(tf.shortLabel).tag(tf)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            Spacer()
            if vm.isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.series == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = vm.error, vm.series == nil {
            ContentUnavailableView("Couldn't load chart",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if let series = vm.series, !series.candles.isEmpty {
            charts(series)
        } else {
            ContentUnavailableView("No price data",
                                   systemImage: "chart.bar.xaxis",
                                   description: Text("\(vm.symbol) has no candles for this timeframe."))
        }
    }

    private func charts(_ series: PriceSeries) -> some View {
        VStack(spacing: 8) {
            priceChart(series)
                .frame(maxHeight: .infinity)
            volumeChart(series)
                .frame(height: 110)
        }
        .padding()
    }

    private func priceChart(_ series: PriceSeries) -> some View {
        Chart {
            ForEach(series.candles, id: \.date) { c in
                RuleMark(
                    x: .value("Date", c.date),
                    yStart: .value("Low", c.low),
                    yEnd: .value("High", c.high)
                )
                .lineStyle(StrokeStyle(lineWidth: 1))
                .foregroundStyle(color(for: c))

                RectangleMark(
                    x: .value("Date", c.date),
                    yStart: .value("Open", c.open),
                    yEnd: .value("Close", c.close),
                    width: .fixed(bodyWidth(series.candles.count))
                )
                .foregroundStyle(color(for: c))
            }
            if let prev = series.previousClose {
                RuleMark(y: .value("Prev Close", prev))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .accessibilityIdentifier("OHLCVPriceChart")
    }

    private func volumeChart(_ series: PriceSeries) -> some View {
        Chart(series.candles, id: \.date) { c in
            BarMark(
                x: .value("Date", c.date),
                y: .value("Volume", c.volume)
            )
            .foregroundStyle(color(for: c).opacity(0.6))
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
        }
        .accessibilityIdentifier("OHLCVVolumeChart")
    }

    private func color(for candle: PriceCandle) -> Color {
        candle.close >= candle.open ? .green : .red
    }

    /// Candle body thickness scaled to how many bars are on screen.
    private func bodyWidth(_ count: Int) -> CGFloat {
        switch count {
        case ..<40: return 8
        case ..<120: return 4
        default: return 2
        }
    }
}

private extension ChartTimeframe {
    /// Compact label for the segmented picker.
    var shortLabel: String {
        switch self {
        case .today: return "1D"
        case .oneWeek: return "1W"
        case .oneMonth: return "1M"
        case .threeMonth: return "3M"
        case .yearToDate: return "YTD"
        case .oneYear: return "1Y"
        case .threeYear: return "3Y"
        case .fiveYear: return "5Y"
        }
    }
}
