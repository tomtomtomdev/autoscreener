import Foundation
import Testing
@testable import Autoscreener

/// Regression for the unbounded breadth fan-out: `BreadthService.reading` used to add
/// one `chartService.candles` task per constituent with no concurrency limit, firing
/// ~45 simultaneous chart requests at Stockbit (which penalises parallel bursts) — a
/// prime source of the `nw_read_request_report … "Operation timed out"` floods. The
/// fan-out must now stay within a fixed concurrency cap.
@Suite struct BreadthConcurrencyTests {
    /// Records the peak number of simultaneous `candles` calls. Each call parks until the
    /// window is full (`cap` calls in flight), then all are released together — so the
    /// observed peak is exactly the cap when the service honours it, but would equal the
    /// symbol count under the old unbounded fan-out. `symbols.count` must be a multiple
    /// of `cap` so every batch fills the window (otherwise a short final batch parks
    /// forever).
    private actor Probe {
        let cap: Int
        private(set) var peak = 0
        private var active = 0
        private var parked: [CheckedContinuation<Void, Never>] = []
        init(cap: Int) { self.cap = cap }

        func arrive() async {
            active += 1
            peak = max(peak, active)
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                parked.append(c)
                if parked.count >= cap { drain() }
            }
            active -= 1
        }

        private func drain() {
            let waiters = parked
            parked.removeAll()
            for w in waiters { w.resume() }
        }
    }

    private final class ProbingChartService: ChartServicing, @unchecked Sendable {
        let probe: Probe
        let series: PriceSeries
        init(probe: Probe, series: PriceSeries) { self.probe = probe; self.series = series }
        func candles(symbol: String, timeframe: ChartTimeframe, chartType: ChartType) async throws -> PriceSeries {
            await probe.arrive()
            return series
        }
    }

    private func risingSeries() -> PriceSeries {
        let day: TimeInterval = 86_400
        let candles = (0..<200).map { i in
            let c = 100 + Double(i)   // steadily rising → latest above its 200-day SMA
            return PriceCandle(date: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * day),
                               open: c, high: c, low: c, close: c, volume: 1_000)
        }
        return PriceSeries(symbol: "X", timeframe: .oneYear, previousClose: nil, candles: candles)
    }

    @Test func fanOutNeverExceedsTheConcurrencyCap() async {
        let cap = 4
        let symbols = (0..<12).map { "S\($0)" }   // 12 = 3 × cap → every batch fills the window
        let probe = Probe(cap: cap)
        let svc = BreadthService(chartService: ProbingChartService(probe: probe, series: risingSeries()),
                                 maxConcurrent: cap)

        let reading = await svc.reading(symbols: symbols, period: 200)

        #expect(await probe.peak == cap)            // window stayed full but never overflowed
        #expect(reading.measured == symbols.count)  // capping didn't drop any name
        #expect(reading.above == symbols.count)     // all rising → all above their MA
    }
}
