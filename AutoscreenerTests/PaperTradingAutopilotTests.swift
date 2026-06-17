import Foundation
import Testing
@testable import Autoscreener

/// Covers the hands-free autopilot: the once-per-trading-day guard, the picks→verdicts→plan→book
/// pipeline, and that a failed picks fetch leaves the day un-stamped so it retries. All offline via
/// injected sources.
@MainActor
@Suite struct PaperTradingAutopilotTests {

    private let gregorian = Calendar(identifier: .gregorian)
    private func day(_ d: Int, _ h: Int = 10) -> Date {
        gregorian.date(from: DateComponents(year: 2026, month: 6, day: d, hour: h))!
    }

    /// Counts how many times the picks source was pulled, so the guard tests can prove no re-fetch.
    @MainActor final class PicksCounter {
        private(set) var calls = 0
        let recommendations: [Recommendation]
        init(_ recommendations: [Recommendation]) { self.recommendations = recommendations }
        func source(_: SelectionConfig) async throws -> SelectionOutcome {
            calls += 1
            return SelectionOutcome(recommendations: recommendations, skipped: [])
        }
    }

    private func rec(_ ticker: String, weight: Double = 0.12) -> Recommendation {
        Recommendation(ticker: ticker, compositeScore: 0.6, intrinsicValue: 10_000,
                       marginOfSafety: 0.3, conviction: 0.6, suggestedWeight: weight, audit: [])
    }

    private func row(_ symbol: String, price: Double) -> ScreenerRow {
        ScreenerRow(symbol: symbol, name: "\(symbol) Co", values: [1, 0], lastPrice: price, pctChange: 0)
    }

    /// Screener (prices/names) + neutral regime + a fresh 100M paper book.
    private func makeStores() -> (ScreenerStore, MarketDataStore, PaperTradingStore) {
        let screener = SweepTestKit.store()
        let snap = ScreenerSnapshot(config: ScreenerConfig(),
                                    rows: [row("BBCA", price: 9_500), row("TLKM", price: 2_800)],
                                    fetchedAt: Date(timeIntervalSince1970: 0))
        for kind in BandarScreenerKind.allCases { screener.apply(snap, for: kind) }
        let market = SweepTestKit.marketStore()
        market.apply(regimeRead: RegimeRead(stance: .neutral, score: 0.0,
                                            factors: [RegimeFactor(kind: .breadth, signal: .neutral, detail: "t")],
                                            asOf: "2026-06-17", valuationCapped: false))
        return (screener, market, PaperTradingStore(fileURL: nil, loadFromDisk: false))
    }

    private func makeAutopilot(_ screener: ScreenerStore, _ market: MarketDataStore, _ paper: PaperTradingStore,
                               recs: RecommendationsStore, exits: ExitDecisionsStore,
                               picks: @escaping (SelectionConfig) async throws -> SelectionOutcome,
                               autoExecute: Bool = true) -> PaperTradingAutopilot {
        PaperTradingAutopilot(
            store: paper, screenerStore: screener, marketStore: market,
            recommendationsStore: recs, exitDecisionsStore: exits,
            picksSource: picks,
            reviewSource: { _ in ReviewOutcome(decisions: [], skipped: []) },
            autoExecute: autoExecute, calendar: gregorian)
    }

    @Test func aDueRunBooksTradesFromTheRecommendations() async {
        let (s, m, p) = makeStores()
        let recs = RecommendationsStore(), exits = ExitDecisionsStore()
        let bot = makeAutopilot(s, m, p, recs: recs, exits: exits,
                                picks: { _ in SelectionOutcome(recommendations: [self.rec("BBCA")], skipped: []) })
        #expect(bot.isDue(now: day(17)))
        await bot.runIfDue(now: day(17))

        #expect(p.state.positions["BBCA"] != nil)                 // booked the buy
        #expect(p.state.positions["BBCA"]?.thesis != nil)         // stamped the entry thesis
        #expect(p.state.lastAutoRebalanceAt == day(17))           // day marked done
        #expect(recs.byTicker["BBCA"] != nil)                     // cache freshened for the screens
    }

    @Test func secondRunSameDayIsANoOp() async {
        let (s, m, p) = makeStores()
        let counter = PicksCounter([rec("BBCA")])
        let bot = makeAutopilot(s, m, p, recs: RecommendationsStore(), exits: ExitDecisionsStore(),
                                picks: counter.source)
        await bot.runIfDue(now: day(17, 10))
        let tradesAfterFirst = p.state.trades.count
        await bot.runIfDue(now: day(17, 15))                      // same calendar day

        #expect(counter.calls == 1)                               // not re-fetched
        #expect(p.state.trades.count == tradesAfterFirst)         // no extra trades
        #expect(!bot.isDue(now: day(17, 23)))
    }

    @Test func nextTradingDayRunsAgain() async {
        let (s, m, p) = makeStores()
        let counter = PicksCounter([rec("BBCA")])
        let bot = makeAutopilot(s, m, p, recs: RecommendationsStore(), exits: ExitDecisionsStore(),
                                picks: counter.source)
        await bot.runIfDue(now: day(17))
        #expect(bot.isDue(now: day(18)))
        await bot.runIfDue(now: day(18))

        #expect(counter.calls == 2)                               // a fresh pull the next day
        #expect(p.state.lastAutoRebalanceAt == day(18))
    }

    @Test func autoExecuteOffRefreshesCachesButBooksNothing() async {
        let (s, m, p) = makeStores()
        let recs = RecommendationsStore()
        let bot = makeAutopilot(s, m, p, recs: recs, exits: ExitDecisionsStore(),
                                picks: { _ in SelectionOutcome(recommendations: [self.rec("BBCA")], skipped: []) },
                                autoExecute: false)
        await bot.runIfDue(now: day(17))

        #expect(p.state.positions.isEmpty)                        // nothing booked
        #expect(recs.byTicker["BBCA"] != nil)                     // but caches still freshened
        #expect(p.state.lastAutoRebalanceAt == day(17))           // and the day counts as done
    }

    @Test func failedPicksFetchLeavesTheDayDueForRetry() async {
        struct Boom: Error {}
        let (s, m, p) = makeStores()
        let bot = makeAutopilot(s, m, p, recs: RecommendationsStore(), exits: ExitDecisionsStore(),
                                picks: { _ in throw Boom() })
        await bot.runIfDue(now: day(17))

        #expect(p.state.positions.isEmpty)
        #expect(p.state.lastAutoRebalanceAt == nil)               // not stamped → still due
        #expect(bot.isDue(now: day(17)))
    }
}
