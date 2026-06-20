import Foundation

/// Pure regime synthesis: maps already-fetched inputs to a `RegimeRead`. This is the
/// logic that used to live in `RegimeViewModel.load()`, lifted out of the view model
/// and away from I/O so the `DataSweepCoordinator` can call it after gathering the
/// inputs through its throttle — and so it stays unit-testable without a network.
///
/// Breadth is derived from the screener's `.above200MA` snapshot via [`IndexBreadth`]
/// rather than a per-constituent chart fan-out, for both the LQ45 leaders and (when its
/// membership is supplied) the broader KOMPAS100 — the divergence breadth factor. Every
/// input is optional: an absent one simply drops its factor (`RegimeFactorBuilder`), and
/// an empty factor set yields `nil` so the caller keeps any prior read.
nonisolated enum RegimeComposer {
    static func compose(
        snapshot: RegimeSnapshot?,
        flow: ForeignFlow?,
        ihsg: PriceSeries?,
        sp500: PriceSeries?,
        usdIdrChangePercent: Double?,
        aboveSnapshot: ScreenerSnapshot?,
        constituents: [String] = LQ45Constituents.symbols,
        kompasConstituents: [String] = [],
        commodityChannel: CommodityChannelReading? = nil
    ) -> RegimeRead? {
        let factors = RegimeFactorBuilder.factors(
            snapshot: snapshot,
            netForeignRaw: flow?.netForeign.raw,
            netForeignText: flow?.netForeign.formatted,
            foreignParticipationPercent: flow?.value.foreignPercentage,
            ihsgDistanceFrom200dma: ihsg.flatMap { MovingAverage.distanceFromSMA($0, period: 200) },
            sp500DistanceFrom200dma: sp500.flatMap { MovingAverage.distanceFromSMA($0, period: 200) },
            usdIdrChangePercent: usdIdrChangePercent,
            breadth: IndexBreadth.reading(aboveSnapshot: aboveSnapshot, constituents: constituents),
            kompasBreadth: IndexBreadth.reading(aboveSnapshot: aboveSnapshot, constituents: kompasConstituents),
            commodityChannel: commodityChannel)

        guard !factors.isEmpty else { return nil }
        return RegimeSynthesizer.read(factors: factors, asOf: snapshot?.asOf)
    }
}
