// BacktestHarness.swift
//
// Part of the same target as StockSelectionEngine.swift. Replays the engine over
// history under a given SelectionConfig and reports return / drawdown / hit-rate
// plus the per-decision audit trail, then sweeps configs to turn "tune the knobs"
// into an optimization loop.
//
// THE ONE RULE THAT MATTERS: no look-ahead. At each rebalance date `t` the engine
// is handed ONLY data available as of `t` (financials reported on/before `t`, bars
// up to `t`). Orders fill at the NEXT bar, never the decision-day close. A backtest
// that violates this looks brilliant and loses money live.
//
// HONEST SIMPLIFICATIONS (documented, tune if they matter to you):
//   • Equity is marked-to-market at rebalance frequency, so drawdown/vol are as
//     granular as your rebalanceDates (use weekly/daily dates for finer curves).
//   • ARA/ARB modelled as: if the fill bar is locked at the limit, the order is
//     skipped that rebalance (re-evaluated next time), not queued.
//   • Hit-rate is realised P&L per sell using average cost (round-trip proxy).

import Foundation

// MARK: - Point-in-time history

/// Time-aware source. The implementation is responsible for returning ONLY
/// information knowable as of `asOf` — this is where look-ahead is prevented.
protocol HistoricalDataSource: Sendable {
    var rebalanceDates: [Date] { get }                                   // ascending
    func universe(asOf: Date) async throws -> [Ticker]
    func data(for t: Ticker, asOf: Date) async throws -> SecurityData    // point-in-time snapshot
    func marketContext(asOf: Date) async throws -> MarketContext
    /// First tradable bar strictly after `date` — the fill bar.
    func nextTradableBar(for t: Ticker, after date: Date) async throws -> OHLCV?
    /// Bar on/at `date` for mark-to-market (nil if not trading / suspended).
    func bar(for t: Ticker, on date: Date) async throws -> OHLCV?
    /// IHSG (or chosen benchmark) bar on `date`.
    func benchmarkClose(on date: Date) async throws -> Double?
}

/// Adapter so the UNCHANGED engine can run against a frozen asOf date.
struct PointInTimeProvider: DataProvider {
    let source: HistoricalDataSource
    let asOf: Date
    func universe() async throws -> [Ticker] { try await source.universe(asOf: asOf) }
    func data(for t: Ticker) async throws -> SecurityData { try await source.data(for: t, asOf: asOf) }
    func marketContext() async throws -> MarketContext { try await source.marketContext(asOf: asOf) }
}

// MARK: - Execution model (IDX microstructure)

struct ExecutionModel: Sendable, Codable {
    enum FillPrice: String, Sendable, Codable { case nextOpen, nextClose }
    var lotSize: Int = 100
    var buyFeePct: Double = 0.0015          // ~0.15% brokerage
    var sellFeePct: Double = 0.0025         // ~0.15% + ~0.1% sell tax
    var slippagePct: Double = 0.0005
    var fillAt: FillPrice = .nextOpen
    var araArbLimit: Double = 0.25          // skip fills on bars locked at the band
    static let standardIDX = ExecutionModel()
}

// MARK: - Portfolio accounting

struct Lot: Sendable { var shares: Double; var avgCost: Double }

struct Portfolio: Sendable {
    var cash: Double
    var positions: [Ticker: Lot] = [:]

    func equity(prices: [Ticker: Double]) -> Double {
        cash + positions.reduce(0) { acc, kv in
            acc + kv.value.shares * (prices[kv.key] ?? kv.value.avgCost)
        }
    }

    /// Returns realised P&L (after fees) if this is a (partial) sell, else 0.
    mutating func apply(side: TradeSide, ticker: Ticker, shares: Double, price: Double,
                        feePct: Double) -> Double {
        guard shares > 0 else { return 0 }
        switch side {
        case .buy:
            let cost = shares * price * (1 + feePct)
            cash -= cost
            var lot = positions[ticker] ?? Lot(shares: 0, avgCost: 0)
            let newShares = lot.shares + shares
            lot.avgCost = newShares > 0 ? (lot.avgCost * lot.shares + price * shares) / newShares : 0
            lot.shares = newShares
            positions[ticker] = lot
            return 0
        case .sell:
            guard var lot = positions[ticker], lot.shares > 0 else { return 0 }
            let qty = min(shares, lot.shares)
            let proceeds = qty * price * (1 - feePct)
            let realised = proceeds - qty * lot.avgCost
            cash += proceeds
            lot.shares -= qty
            if lot.shares <= 0 { positions[ticker] = nil } else { positions[ticker] = lot }
            return realised
        }
    }
}

/// Buy or sell. Carries a `String` raw value + `Codable` so the live paper-trading
/// layer can persist fills and label plan rows with the same type the backtester uses.
enum TradeSide: String, Sendable, Codable, Hashable { case buy, sell }

// MARK: - Report

struct BacktestReport: Sendable {
    let label: String
    let startEquity: Double
    let endEquity: Double
    let totalReturn: Double
    let cagr: Double
    let maxDrawdown: Double
    let annualizedVol: Double
    let benchmarkReturn: Double
    let excessReturn: Double
    let hitRate: Double
    let trades: Int
    let turnover: Double
    let equityCurve: [(date: Date, equity: Double)]
    let decisions: [(date: Date, picks: [Recommendation])]   // full audit per rebalance

    /// Default sweep objective: return per unit of drawdown (a crude Calmar).
    /// Swap for Sharpe, raw CAGR, etc. when ranking configs.
    var objective: Double { cagr / max(maxDrawdown, 0.01) }
}

// MARK: - Backtester

struct Backtester: Sendable {
    let source: HistoricalDataSource
    let config: SelectionConfig
    let execution: ExecutionModel
    let initialCapital: Double

    init(source: HistoricalDataSource, config: SelectionConfig = .balanced,
         execution: ExecutionModel = .standardIDX, initialCapital: Double = 1_000_000_000) {
        self.source = source; self.config = config
        self.execution = execution; self.initialCapital = initialCapital
    }

    func run(label: String) async throws -> BacktestReport {
        var pf = Portfolio(cash: initialCapital)
        var curve: [(Date, Double)] = []
        var decisions: [(Date, [Recommendation])] = []
        var tradedValue = 0.0, equitySum = 0.0
        var wins = 0, closes = 0
        var benchStart: Double?, benchEnd: Double?

        let dates = source.rebalanceDates
        for date in dates {
            // 1. Mark-to-market at this date's close → record equity point.
            let mtm = try await prices(for: Array(pf.positions.keys), on: date)
            let eq = pf.equity(prices: mtm)
            curve.append((date, eq)); equitySum += eq
            if let b = try await source.benchmarkClose(on: date) {
                benchStart = benchStart ?? b; benchEnd = b
            }

            // 2. Decide using ONLY data as of `date` (no look-ahead).
            let engine = StockSelectionEngine(provider: PointInTimeProvider(source: source, asOf: date),
                                              config: config)
            let picks = try await engine.run()
            decisions.append((date, picks))

            // 3. Build target share map from weights × current equity.
            var targetShares: [Ticker: Double] = [:]
            for p in picks {
                guard let bar = try await source.nextTradableBar(for: p.ticker, after: date) else { continue }
                let fill = fillPrice(bar)
                let lots = floor((p.suggestedWeight * eq) / (fill * Double(execution.lotSize)))
                targetShares[p.ticker] = max(0, lots) * Double(execution.lotSize)
            }

            // 4. Diff current → target, execute at the next bar with costs/lots/ARA-ARB.
            let names = Set(pf.positions.keys).union(targetShares.keys)
            for t in names {
                let have = pf.positions[t]?.shares ?? 0
                let want = targetShares[t] ?? 0
                let delta = want - have
                if abs(delta) < Double(execution.lotSize) { continue }
                guard let bar = try await source.nextTradableBar(for: t, after: date) else { continue }
                guard !isLocked(bar) else { continue }                  // ARA/ARB: skip locked bar
                let side: TradeSide = delta > 0 ? .buy : .sell
                let qty = (abs(delta) / Double(execution.lotSize)).rounded(.down) * Double(execution.lotSize)
                if qty <= 0 { continue }
                let px = fillPrice(bar) * (side == .buy ? (1 + execution.slippagePct) : (1 - execution.slippagePct))
                let feePct = side == .buy ? execution.buyFeePct : execution.sellFeePct
                let realised = pf.apply(side: side, ticker: t, shares: qty, price: px, feePct: feePct)
                tradedValue += qty * px
                if side == .sell { closes += 1; if realised > 0 { wins += 1 } }
            }
        }

        // Final mark-to-market on the last date.
        let lastDate = dates.last ?? Date()
        let finalPrices = try await prices(for: Array(pf.positions.keys), on: lastDate)
        let endEquity = pf.equity(prices: finalPrices)
        if curve.last?.0 != lastDate { curve.append((lastDate, endEquity)) }

        return makeReport(label: label, curve: curve, endEquity: endEquity, decisions: decisions,
                          tradedValue: tradedValue, avgEquity: equitySum / Double(max(curve.count, 1)),
                          wins: wins, closes: closes, benchStart: benchStart, benchEnd: benchEnd,
                          years: years(dates))
    }

    // -- helpers --

    private func fillPrice(_ b: OHLCV) -> Double {
        dbl(execution.fillAt == .nextOpen ? b.open : b.close)
    }
    private func isLocked(_ b: OHLCV) -> Bool {
        // A single bar can't prove an auto-reject, so use an honest proxy: a bar
        // with zero intraday range (high == low) didn't trade through any price and
        // is treated as untradeable. If your data carries explicit ARA/ARB band
        // prices, replace this with a gap-to-limit test using execution.araArbLimit.
        guard dbl(b.open) > 0 else { return true }
        return b.high == b.low
    }
    private func prices(for tickers: [Ticker], on date: Date) async throws -> [Ticker: Double] {
        var out: [Ticker: Double] = [:]
        for t in tickers { if let b = try await source.bar(for: t, on: date) { out[t] = dbl(b.close) } }
        return out
    }
    private func years(_ dates: [Date]) -> Double {
        guard let f = dates.first, let l = dates.last, l > f else { return 1 }
        return max(l.timeIntervalSince(f) / (365.25 * 86400), 1.0 / 12)
    }

    private func makeReport(label: String, curve: [(Date, Double)], endEquity: Double,
                            decisions: [(Date, [Recommendation])], tradedValue: Double,
                            avgEquity: Double, wins: Int, closes: Int,
                            benchStart: Double?, benchEnd: Double?, years: Double) -> BacktestReport {
        let start = curve.first?.1 ?? initialCapital
        let total = start > 0 ? (endEquity - start) / start : 0
        let cagr = start > 0 ? pow(endEquity / start, 1.0 / years) - 1 : 0

        // Max drawdown over the (rebalance-frequency) equity curve.
        var peak = start, maxDD = 0.0
        for (_, e) in curve { peak = max(peak, e); maxDD = max(maxDD, (peak - e) / peak) }

        // Annualised vol from period returns (scaled by periods/year).
        let eqs = curve.map(\.1)
        let rets = zip(eqs, eqs.dropFirst()).map { $1 / $0 - 1 }
        let perYear = Double(max(curve.count - 1, 1)) / years
        let annVol = stddev(rets) * (perYear).squareRoot()

        let bench = (benchStart.map { ($0 ?? 0) > 0 } ?? false) ? (benchEnd! / benchStart! - 1) : 0
        return BacktestReport(
            label: label, startEquity: start, endEquity: endEquity, totalReturn: total, cagr: cagr,
            maxDrawdown: maxDD, annualizedVol: annVol, benchmarkReturn: bench,
            excessReturn: total - bench, hitRate: closes > 0 ? Double(wins) / Double(closes) : 0,
            trades: closes, turnover: avgEquity > 0 ? tradedValue / avgEquity : 0,
            equityCurve: curve.map { (date: $0.0, equity: $0.1) }, decisions: decisions.map { (date: $0.0, picks: $0.1) })
    }
}

// MARK: - Config sweep (the optimization loop)

enum ConfigSweep {
    /// Build variants by walking one parameter across values via a writable key path.
    /// Example:
    ///   let variants = ConfigSweep.grid(.balanced, \.forensic.accrualsMax, [0.08, 0.12, 0.15, 0.20]) {
    ///       "accruals<=\($0)"
    ///   }
    static func grid<V>(_ base: SelectionConfig, _ keyPath: WritableKeyPath<SelectionConfig, V>,
                        _ values: [V], _ label: (V) -> String) -> [(String, SelectionConfig)] {
        values.map { v in
            var c = base; c[keyPath: keyPath] = v
            return (label(v), c)
        }
    }

    /// Run every variant and return reports ranked by `objective` (descending).
    static func run(_ variants: [(String, SelectionConfig)], source: HistoricalDataSource,
                    execution: ExecutionModel = .standardIDX,
                    initialCapital: Double = 1_000_000_000,
                    rankBy: @Sendable (BacktestReport) -> Double = { $0.objective }) async throws -> [BacktestReport] {
        var reports: [BacktestReport] = []
        for (label, cfg) in variants {
            let bt = Backtester(source: source, config: cfg, execution: execution, initialCapital: initialCapital)
            reports.append(try await bt.run(label: label))
        }
        return reports.sorted { rankBy($0) > rankBy($1) }
    }

    /// Convenience: compare the four shipped presets head-to-head.
    static func presetShootout(source: HistoricalDataSource,
                               execution: ExecutionModel = .standardIDX) async throws -> [BacktestReport] {
        try await run([("defensive", .defensive), ("balanced", .balanced),
                       ("deepValue", .deepValue), ("growth", .growth)],
                      source: source, execution: execution)
    }
}

// MARK: - Local helpers (this file)

private func dbl(_ d: Decimal) -> Double { (d as NSDecimalNumber).doubleValue }
private func stddev(_ xs: [Double]) -> Double {
    guard xs.count > 1 else { return 0 }
    let m = xs.reduce(0, +) / Double(xs.count)
    return (xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count - 1)).squareRoot()
}

// MARK: - Usage sketch
//
//   let source: HistoricalDataSource = MyIDXReplaySource(...)   // your FastAPI/SQLite layer
//
//   // Single run with full audit:
//   let report = try await Backtester(source: source, config: .deepValue).run(label: "deepValue")
//   print(report.cagr, report.maxDrawdown, report.hitRate, report.excessReturn)
//   for (date, picks) in report.decisions { /* picks[i].audit is the decision trail */ }
//
//   // Preset shootout:
//   let ranked = try await ConfigSweep.presetShootout(source: source)
//
//   // One-parameter sweep:
//   let variants = ConfigSweep.grid(.balanced, \.regime.neutralPolicy.minMarginOfSafety,
//                                   [0.20, 0.30, 0.40, 0.50]) { "MoS>=\($0)" }
//   let tuned = try await ConfigSweep.run(variants, source: source,
//                                         rankBy: { $0.cagr - 0.5 * $0.maxDrawdown })
