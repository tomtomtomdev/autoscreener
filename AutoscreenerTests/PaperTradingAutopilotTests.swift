import Foundation
import Testing
@testable import Autoscreener

/// Covers the hands-free autopilot: the once-per-session-boundary guard (open / break / close), the
/// picks→verdicts→plan→book pipeline, that a failed picks fetch leaves the boundary un-stamped to
/// retry, and that a cold sweep with no priced candidates yet doesn't burn the boundary's slot. All
/// offline via injected sources, on an IDX (Asia/Jakarta) clock.
@MainActor
@Suite struct PaperTradingAutopilotTests {

    private let jakarta = TimeZone(identifier: "Asia/Jakarta")!
    /// The same zone `day(_:_:)` builds dates in, so session-boundary math is deterministic.
    private let gregorian: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Jakarta")!
        return c
    }()
    private var clock: MarketClock { MarketClock(timeZone: jakarta) }
    /// 2026-06-17 is a Wednesday; `h` is the hour-of-day in Jakarta.
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

    /// Picks source whose output can change between calls — models a cold cache (no recommendations)
    /// that warms into a real pick on a later sweep.
    @MainActor final class StagedPicks {
        var recommendations: [Recommendation]
        private(set) var calls = 0
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
                               review: @escaping (SelectionConfig) async throws -> ReviewOutcome
                                  = { _ in ReviewOutcome(decisions: [], skipped: []) },
                               config: AllocationConfig = .standard,
                               autoExecute: Bool = true) -> PaperTradingAutopilot {
        PaperTradingAutopilot(
            store: paper, screenerStore: screener, marketStore: market,
            recommendationsStore: recs, exitDecisionsStore: exits,
            picksSource: picks,
            reviewSource: review,
            config: config,
            autoExecute: autoExecute, calendar: gregorian, clock: clock)
    }

    /// Stores like `makeStores()` but with a deeply RISK-OFF regime, to contrast the two books.
    private func makeRiskOffStores() -> (ScreenerStore, MarketDataStore) {
        let screener = SweepTestKit.store()
        let snap = ScreenerSnapshot(config: ScreenerConfig(),
                                    rows: [row("BBCA", price: 9_500), row("TLKM", price: 2_800)],
                                    fetchedAt: Date(timeIntervalSince1970: 0))
        for kind in BandarScreenerKind.allCases { screener.apply(snap, for: kind) }
        let market = SweepTestKit.marketStore()
        market.apply(regimeRead: RegimeRead(stance: .riskOff, score: -0.9,
                                            factors: [RegimeFactor(kind: .breadth, signal: .riskOff, detail: "t")],
                                            asOf: "2026-06-17", valuationCapped: false))
        return (screener, market)
    }

    /// Review source whose verdicts can change between sweeps — models a thesis breaking after entry.
    @MainActor final class StagedReview {
        var decisions: [ExitDecision]
        init(_ decisions: [ExitDecision] = []) { self.decisions = decisions }
        func source(_: SelectionConfig) async throws -> ReviewOutcome {
            ReviewOutcome(decisions: decisions, skipped: [])
        }
    }

    private func exit(_ ticker: String) -> ExitDecision {
        ExitDecision(ticker: ticker, action: .exit, reason: "test break", audit: [])
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
        #expect(p.state.lastAutoRebalanceAt == day(17))           // boundary marked done
        #expect(recs.byTicker["BBCA"] != nil)                     // cache freshened for the screens
    }

    @Test func secondRunWithinTheSameSessionBoundaryIsANoOp() async {
        let (s, m, p) = makeStores()
        let counter = PicksCounter([rec("BBCA")])
        let bot = makeAutopilot(s, m, p, recs: RecommendationsStore(), exits: ExitDecisionsStore(),
                                picks: counter.source)
        await bot.runIfDue(now: day(17, 10))                      // 10:00 — inside the 09:00 open window
        let tradesAfterFirst = p.state.trades.count
        await bot.runIfDue(now: day(17, 11))                      // 11:00 — still the same open boundary

        #expect(counter.calls == 1)                               // not re-fetched
        #expect(p.state.trades.count == tradesAfterFirst)         // no extra trades
        #expect(!bot.isDue(now: day(17, 11)))                     // still satisfied for this boundary
    }

    @Test func crossingIntoTheNextSessionBoundaryReRunsSameDay() async {
        let (s, m, p) = makeStores()
        let counter = PicksCounter([rec("BBCA")])
        let bot = makeAutopilot(s, m, p, recs: RecommendationsStore(), exits: ExitDecisionsStore(),
                                picks: counter.source)
        await bot.runIfDue(now: day(17, 10))                      // open boundary (09:00)
        #expect(bot.isDue(now: day(17, 14)))                      // 14:00 → past the 13:30 resume boundary
        await bot.runIfDue(now: day(17, 14))

        #expect(counter.calls == 2)                               // a fresh pull at the new boundary
        #expect(p.state.lastAutoRebalanceAt == day(17, 14))
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
        #expect(p.state.lastAutoRebalanceAt == day(17))           // and the boundary counts as done
    }

    @Test func failedPicksFetchLeavesTheBoundaryDueForRetry() async {
        struct Boom: Error {}
        let (s, m, p) = makeStores()
        let bot = makeAutopilot(s, m, p, recs: RecommendationsStore(), exits: ExitDecisionsStore(),
                                picks: { _ in throw Boom() })
        await bot.runIfDue(now: day(17))

        #expect(p.state.positions.isEmpty)
        #expect(p.state.lastAutoRebalanceAt == nil)               // not stamped → still due
        #expect(bot.isDue(now: day(17)))
    }

    /// Regression for the "stuck at 100% cash" bug: the first sweep of a boundary fired while the
    /// per-symbol cache was still cold (selection returned nothing). The autopilot must NOT consume the
    /// boundary on an empty, no-candidate plan — it should leave it due so the next (warm) sweep books.
    @Test func coldNoCandidateRunDoesNotConsumeTheBoundaryThenBooksWhenWarm() async {
        let (s, m, p) = makeStores()
        let staged = StagedPicks([])                              // cache cold: no recommendations yet
        let bot = makeAutopilot(s, m, p, recs: RecommendationsStore(), exits: ExitDecisionsStore(),
                                picks: staged.source)
        await bot.runIfDue(now: day(17, 9))                       // 09:00 open, cold

        #expect(p.state.positions.isEmpty)                        // nothing booked
        #expect(p.state.lastAutoRebalanceAt == nil)               // boundary NOT consumed
        #expect(bot.isDue(now: day(17, 10)))                      // still due in the same open window

        staged.recommendations = [rec("BBCA")]                    // cache warms — the real pick lands
        await bot.runIfDue(now: day(17, 10))

        #expect(p.state.positions["BBCA"] != nil)                 // now it books on the same boundary
        #expect(p.state.lastAutoRebalanceAt == day(17, 10))
    }

    // MARK: - Asymmetric defense: exits run every warm sweep, not just at boundaries

    /// The core of the buy/sell asymmetry: a name that breaks after entry is liquidated on the very next
    /// warm sweep — even when no session boundary has been crossed (so the rebalance pass is NOT due).
    @Test func exitVerdictLiquidatesWithoutWaitingForABoundary() async {
        let (s, m, p) = makeStores()
        let staged = StagedReview()                               // intact at entry
        let bot = makeAutopilot(s, m, p, recs: RecommendationsStore(), exits: ExitDecisionsStore(),
                                picks: { _ in SelectionOutcome(recommendations: [self.rec("BBCA")], skipped: []) },
                                review: staged.source)
        await bot.runIfDue(now: day(17, 10))                      // open boundary → buys BBCA
        #expect(p.state.positions["BBCA"] != nil)

        staged.decisions = [exit("BBCA")]                         // thesis breaks intraday
        #expect(!bot.isDue(now: day(17, 11)))                     // still the same boundary — no rebalance due
        await bot.runExits(now: day(17, 11))                      // defense pass on a mid-session sweep

        #expect(p.state.positions["BBCA"] == nil)                 // sold now — didn't wait for the next boundary
        #expect(p.state.trades.contains { $0.symbol == "BBCA" && $0.side == .sell })
    }

    // MARK: - Regime-blind (RiBeTS) book

    /// The defining RiBeTS behaviour: under a deeply risk-off regime, the regime-AWARE book parks in cash
    /// while the regime-BLIND book (`.regimeBlind`) still deploys off the same recommendations. Each books
    /// into its OWN store, so the two run independently.
    @Test func regimeBlindBookDeploysInRiskOffWhileTheAwareBookStaysInCash() async {
        let (s, m) = makeRiskOffStores()
        let rapats = PaperTradingStore(fileURL: nil, loadFromDisk: false)
        let ribets = PaperTradingStore(fileURL: nil, loadFromDisk: false)
        let picks: (SelectionConfig) async throws -> SelectionOutcome = { _ in
            SelectionOutcome(recommendations: [self.rec("BBCA"), self.rec("TLKM")], skipped: [])
        }
        let aware = makeAutopilot(s, m, rapats, recs: RecommendationsStore(), exits: ExitDecisionsStore(),
                                  picks: picks, config: .standard)
        let blind = makeAutopilot(s, m, ribets, recs: RecommendationsStore(), exits: ExitDecisionsStore(),
                                  picks: picks, config: .regimeBlind)

        await aware.runIfDue(now: day(17))
        await blind.runIfDue(now: day(17))

        #expect(!ribets.state.positions.isEmpty)              // blind deploys despite risk-off
        #expect(ribets.state.cash < rapats.state.cash)        // …and holds far less cash than the aware book
        // Independence: each autopilot only touched its own book.
        #expect(rapats.state.cash <= PaperPortfolioState.seed.cash)
    }

    /// The two books are fully independent: running the RiBeTS autopilot never mutates the RAPaTS book.
    @Test func runningTheRiBeTSBookLeavesTheRAPaTSBookUntouched() async {
        let (s, m) = makeRiskOffStores()
        let rapats = PaperTradingStore(fileURL: nil, loadFromDisk: false)
        let ribets = PaperTradingStore(fileURL: nil, loadFromDisk: false)
        let blind = makeAutopilot(s, m, ribets, recs: RecommendationsStore(), exits: ExitDecisionsStore(),
                                  picks: { _ in SelectionOutcome(recommendations: [self.rec("BBCA")], skipped: []) },
                                  config: .regimeBlind)

        await blind.run(now: day(17))

        #expect(!ribets.state.positions.isEmpty)              // RiBeTS booked
        #expect(rapats.state.positions.isEmpty)               // RAPaTS untouched (separate store)
        #expect(rapats.state.lastAutoRebalanceAt == nil)
    }

    /// The exit pass is sell-only and verdict-driven: an unflagged holding is left completely alone
    /// (no rebalancing/trimming leaks into the every-sweep cadence).
    @Test func exitPassLeavesUnflaggedHoldingsAlone() async {
        let (s, m, p) = makeStores()
        let staged = StagedReview()
        let bot = makeAutopilot(s, m, p, recs: RecommendationsStore(), exits: ExitDecisionsStore(),
                                picks: { _ in SelectionOutcome(recommendations: [self.rec("BBCA")], skipped: []) },
                                review: staged.source)
        await bot.runIfDue(now: day(17, 10))
        let sharesAfterBuy = p.state.positions["BBCA"]?.shares
        #expect(sharesAfterBuy != nil)

        staged.decisions = []                                     // no verdict ⇒ hold
        await bot.runExits(now: day(17, 11))

        #expect(p.state.positions["BBCA"]?.shares == sharesAfterBuy)  // untouched by the defense pass
    }
}
