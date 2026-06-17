import Foundation

/// How many of a basket's names are above their own long-term moving average — the
/// market-breadth input to the regime read (`idx-investing-research.md` §3). A
/// rising index carried by a handful of mega-caps (narrow breadth) is a weaker,
/// later-cycle tape than a broad advance; breadth is what tells them apart.
nonisolated struct BreadthReading: Sendable, Equatable {
    /// Names whose latest close is above their `period`-day moving average.
    let above: Int
    /// Names we actually got chartable history for (the honest denominator — a
    /// constituent that failed to load or lacks 200 days of data isn't counted).
    let measured: Int

    /// Share of measured names above their MA, 0…1, or `nil` when none were measurable.
    var fraction: Double? { measured > 0 ? Double(above) / Double(measured) : nil }
}

nonisolated protocol BreadthServicing: Sendable {
    func reading(symbols: [String], period: Int) async -> BreadthReading
}

extension BreadthServicing {
    /// Classic 200-day breadth (the regime default).
    func reading(symbols: [String]) async -> BreadthReading {
        await reading(symbols: symbols, period: 200)
    }
}

/// Computes breadth by fanning out one daily-chart request per constituent and
/// counting how many close above their `period`-day SMA. Per-name failure is
/// tolerated — a paywalled or illiquid name is simply absent from `measured`
/// rather than failing the whole read (mirrors `MarketQuotesViewModel`).
nonisolated final class BreadthService: BreadthServicing {
    private let chartService: any ChartServicing
    /// Upper bound on chart requests in flight at once. Stockbit penalises parallel
    /// bursts, and a constituent basket can be ~45 names — firing them all at once
    /// timed sockets out (the `nw_read_request_report … "Operation timed out"` floods).
    /// We process the basket in windows of this size instead.
    private let maxConcurrent: Int

    init(chartService: any ChartServicing, maxConcurrent: Int = 6) {
        self.chartService = chartService
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func reading(symbols: [String], period: Int) async -> BreadthReading {
        let chartService = self.chartService
        var above = 0, measured = 0
        var index = 0
        while index < symbols.count {
            let window = symbols[index..<min(index + maxConcurrent, symbols.count)]
            index += maxConcurrent
            await withTaskGroup(of: Bool?.self) { group in
                for symbol in window {
                    group.addTask {
                        guard let series = try? await chartService.candles(symbol: symbol, timeframe: .oneYear)
                        else { return nil }
                        return MovingAverage.isAboveSMA(series, period: period)
                    }
                }
                for await result in group {
                    guard let isAbove = result else { continue }
                    measured += 1
                    if isAbove { above += 1 }
                }
            }
        }
        return BreadthReading(above: above, measured: measured)
    }
}
