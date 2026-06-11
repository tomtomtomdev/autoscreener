import Foundation
import Observation

/// Drives the Market Regime screen. Fans out the four-layer regime inputs
/// (`idx-investing-research.md` §3) concurrently — the server valuation/BI-rate
/// snapshot, aggregate foreign flow, the IHSG 200-day trend, the rupiah, and LQ45
/// breadth — then runs `RegimeSynthesizer` to produce the risk-on / neutral /
/// risk-off read. Every input is fetched tolerantly: a feed that fails (or the
/// snapshot that isn't published yet) simply drops its factor rather than failing
/// the whole screen, matching `MarketQuotesViewModel`.
@MainActor
@Observable
final class RegimeViewModel {
    private(set) var read: RegimeRead?
    var isLoading = false
    var error: String?

    private let snapshotProvider: any RegimeSnapshotProviding
    private let flowService: any AggregateForeignFlowServicing
    private let chartService: any ChartServicing
    private let commodityService: any CommodityPriceServicing
    private let breadthService: any BreadthServicing
    private let constituents: [String]
    private var hasLoaded = false

    /// IHSG — the composite index, for the 200-day trend signal.
    private static let compositeSymbol = "IHSG"
    /// S&P 500 — Stockbit serves global indices on the same `charts/{symbol}/daily`
    /// path; its 200-day trend is the live global risk-appetite leg.
    private static let globalEquitySymbol = "SP500"
    /// USD/IDR — the rupiah snapshot (a currency, so price-only, no chart history).
    private static let rupiahSymbol = "USDIDR"

    init(snapshotProvider: any RegimeSnapshotProviding = AppDependencies.shared.regimeSnapshotService,
         flowService: any AggregateForeignFlowServicing = AppDependencies.shared.aggregateForeignFlowService,
         chartService: any ChartServicing = AppDependencies.shared.chartService,
         commodityService: any CommodityPriceServicing = AppDependencies.shared.commodityPriceService,
         breadthService: any BreadthServicing = AppDependencies.shared.breadthService,
         constituents: [String] = LQ45Constituents.symbols) {
        self.snapshotProvider = snapshotProvider
        self.flowService = flowService
        self.chartService = chartService
        self.commodityService = commodityService
        self.breadthService = breadthService
        self.constituents = constituents
    }

    func load(force: Bool = false) async {
        if !force, hasLoaded { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        // Fan out every input concurrently; wall-clock ≈ the slowest single fetch.
        async let snapshotTask = snapshotProvider.snapshot()
        async let flowTask = flowService.marketFlow()
        async let ihsgTask = chartService.candles(symbol: Self.compositeSymbol, timeframe: .oneYear)
        async let sp500Task = chartService.candles(symbol: Self.globalEquitySymbol, timeframe: .oneYear)
        async let rupiahTask = commodityService.quote(symbol: Self.rupiahSymbol)
        async let breadthTask = breadthService.reading(symbols: constituents)

        let snapshot = try? await snapshotTask
        let flow = try? await flowTask
        let ihsg = try? await ihsgTask
        let sp500 = try? await sp500Task
        let rupiah = try? await rupiahTask
        let breadth = await breadthTask

        let factors = RegimeFactorBuilder.factors(
            snapshot: snapshot,
            netForeignRaw: flow?.netForeign.raw,
            netForeignText: flow?.netForeign.formatted,
            ihsgDistanceFrom200dma: ihsg.flatMap { MovingAverage.distanceFromSMA($0, period: 200) },
            sp500DistanceFrom200dma: sp500.flatMap { MovingAverage.distanceFromSMA($0, period: 200) },
            usdIdrChangePercent: rupiah?.changePercent,
            breadth: breadth)

        guard !factors.isEmpty else {
            // Every input failed — keep any prior read, surface an error, and leave
            // `hasLoaded` false so the next appearance retries.
            error = "Couldn't load the regime inputs. Pull to retry."
            return
        }
        read = RegimeSynthesizer.read(factors: factors, asOf: snapshot?.asOf)
        hasLoaded = true
    }
}
