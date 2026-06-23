import Foundation
import Testing
@testable import Autoscreener

/// Regression coverage for the sweep-hang bug: a flaky network after market close left the per-symbol
/// cache-warming loop grinding through the entire universe (each dead request burning ~90s), so the
/// sweep never returned, `isSweeping` stayed true, and the title bar froze on "Fetching 20/20" while
/// the Recommendations screen sat on "waiting for the data sweep". `SecurityCacheWarmer` bounds the
/// loop with an offline circuit breaker (consecutive transport failures) so it returns promptly when
/// the feed is unreachable, while letting a healthy-but-slow warm run to completion.
@Suite @MainActor struct SecurityCacheWarmerTests {

    /// Counts per-name fetch attempts (the SLOW leg, fetched first) and throws a configured error, so
    /// the tests can prove the loop stopped early (call count ≪ universe) instead of marching through
    /// every name. `liveSignals` is never reached when `fundamentals` throws.
    private actor StubProvider: LegProvider {
        let dataError: Error
        let contextError: Error
        private(set) var dataCallCount = 0

        init(dataError: Error, contextError: Error) {
            self.dataError = dataError
            self.contextError = contextError
        }

        func fundamentals(for t: Ticker, onStep: (@MainActor (String) -> Void)? = nil) async throws -> FundamentalSlice {
            dataCallCount += 1
            throw dataError
        }
        func liveSignals(for t: Ticker, sectorIndexSymbol: String?, onStep: (@MainActor (String) -> Void)? = nil) async throws -> LiveSlice {
            throw dataError   // unreached (the slow leg throws first); present for conformance.
        }
        func marketContext() async throws -> MarketContext { throw contextError }
    }

    /// Replays a scripted sequence of per-ticker outcomes (success vs. a specific error), so the
    /// "a success resets the breaker" property can be exercised deterministically.
    private actor SequencedProvider: LegProvider {
        private var results: [Result<Void, Error>]
        private var index = 0
        let contextError: Error
        private(set) var dataCallCount = 0

        init(results: [Result<Void, Error>], contextError: Error) {
            self.results = results
            self.contextError = contextError
        }

        func fundamentals(for t: Ticker, onStep: (@MainActor (String) -> Void)? = nil) async throws -> FundamentalSlice {
            defer { dataCallCount += 1 }
            let result = index < results.count ? results[index] : .failure(URLError(.timedOut))
            index += 1
            switch result {
            case .success:          return Self.barrenFundamental()
            case .failure(let e):   throw e
            }
        }
        func liveSignals(for t: Ticker, sectorIndexSymbol: String?, onStep: (@MainActor (String) -> Void)? = nil) async throws -> LiveSlice {
            Self.barrenLive()   // only reached after a successful slow leg; no result consumed
        }
        func marketContext() async throws -> MarketContext { throw contextError }

        /// Bar-less, financials-less slices — enough to stand in for a successful fetch without
        /// recreating the scoring Object Mother (the warmer doesn't inspect their contents).
        static func barrenFundamental() -> FundamentalSlice {
            FundamentalSlice(
                sector: "Industrials", sharesOutstanding: 0, freeFloatPct: 0, financials: [],
                ttm: TTMFinancials(eps: 0, bookValuePerShare: 0, netIncome: 0, operatingCashFlow: 0,
                                   totalAssets: 0, epsGrowthPct: 0, currentRatio: 0, debtToEquity: 0,
                                   returnOnEquity: 0),
                sectorIndexSymbol: nil, peerComparison: nil, seasonality: nil,
                analystCoverage: nil, governance: nil)
        }
        static func barrenLive() -> LiveSlice {
            LiveSlice(price: 0, dailyBars: [], foreignNetFlow: [], brokerAccumulationSignal: 0,
                      sectorIndexBars: [], marketIndexBars: [], brokerDistribution: nil)
        }
    }

    /// Returns fixed slices for one name, so a test can prove the warmer writes BOTH cadence stores and
    /// composes the slow `sector` + fast `price` into the engine's `SecurityData`.
    private struct OneNameProvider: LegProvider {
        let fundamental: FundamentalSlice
        let live: LiveSlice
        func fundamentals(for t: Ticker, onStep: (@MainActor (String) -> Void)? = nil) async throws -> FundamentalSlice { fundamental }
        func liveSignals(for t: Ticker, sectorIndexSymbol: String?, onStep: (@MainActor (String) -> Void)? = nil) async throws -> LiveSlice { live }
        func marketContext() async throws -> MarketContext { throw SelectionProviderError.noRegimeInputs }
    }

    /// Counts each cadence leg separately, so a test can prove an intraday pass fetches ONLY the fast
    /// leg (reusing cached fundamentals) while a cold name fetches both.
    private actor CountingProvider: LegProvider {
        private(set) var fundamentalsCalls = 0
        private(set) var liveCalls = 0
        let fundamental: FundamentalSlice
        let live: LiveSlice
        init(fundamental: FundamentalSlice, live: LiveSlice) {
            self.fundamental = fundamental
            self.live = live
        }
        func fundamentals(for t: Ticker, onStep: (@MainActor (String) -> Void)? = nil) async throws -> FundamentalSlice {
            fundamentalsCalls += 1; return fundamental
        }
        func liveSignals(for t: Ticker, sectorIndexSymbol: String?, onStep: (@MainActor (String) -> Void)? = nil) async throws -> LiveSlice {
            liveCalls += 1; return live
        }
        func marketContext() async throws -> MarketContext { throw SelectionProviderError.noRegimeInputs }
    }

    private func liveSlice(price: Rupiah) -> LiveSlice {
        LiveSlice(price: price, dailyBars: [], foreignNetFlow: [], brokerAccumulationSignal: 0,
                  sectorIndexBars: [], marketIndexBars: [], brokerDistribution: nil)
    }
    private func fundamentalSlice(sector: String, sectorIndexSymbol: String?) -> FundamentalSlice {
        FundamentalSlice(
            sector: sector, sharesOutstanding: 0, freeFloatPct: 0, financials: [],
            ttm: TTMFinancials(eps: 0, bookValuePerShare: 0, netIncome: 0, operatingCashFlow: 0,
                               totalAssets: 0, epsGrowthPct: 0, currentRatio: 0, debtToEquity: 0,
                               returnOnEquity: 0),
            sectorIndexSymbol: sectorIndexSymbol, peerComparison: nil, seasonality: nil,
            analystCoverage: nil, governance: nil)
    }

    private static let timeout = URLError(.timedOut)
    private static let noPrice = SelectionProviderError.noPriceData("X")
    private static func universe(_ n: Int) -> [Ticker] { (1...n).map { "T\($0)" } }

    // MARK: - Offline circuit breaker

    @Test func stopsAfterConsecutiveTransportFailuresInsteadOfDrainingTheUniverse() async {
        // The bug condition: the feed is dead and every request times out.
        let provider = StubProvider(dataError: Self.timeout, contextError: Self.timeout)
        let warmer = SecurityCacheWarmer(provider: provider, maxConsecutiveTransportFailures: 3)

        let outcome = await warmer.warm(
            universe: Self.universe(50), onContext: { _ in }, onData: { _, _ in })

        #expect(outcome.abortedOffline)                 // surfaced as offline, not a silent stall
        #expect(outcome.warmed == 0)
        let calls = await provider.dataCallCount
        #expect(calls <= 3)                             // bounded — NOT all 50 (the bug drained them)
    }

    // MARK: - Valuation skips are neutral (must not trip the breaker)

    @Test func valuationSkipsNeverTripTheBreakerSoEveryNameIsAttempted() async {
        // A run of un-valuable names (no price) is expected, not an outage — warm them all.
        let provider = StubProvider(
            dataError: Self.noPrice, contextError: SelectionProviderError.noRegimeInputs)
        let warmer = SecurityCacheWarmer(provider: provider, maxConsecutiveTransportFailures: 3)

        var progress: [(Int, Int)] = []
        let outcome = await warmer.warm(
            universe: Self.universe(50), onContext: { _ in }, onData: { _, _ in },
            onProgress: { done, total, _, _ in progress.append((done, total)) })

        #expect(!outcome.abortedOffline)
        let calls = await provider.dataCallCount
        #expect(calls == 50)                            // breaker stayed shut across all skips
        #expect(progress.last?.0 == 50 && progress.last?.1 == 50)
    }

    // MARK: - Progress names the in-flight ticker (title bar shows "Warming BBCA x/y")

    @Test func progressAnnouncesEachTickerBeingWarmedInOrderThenClearsIt() async {
        // The warmer reports the name it's about to fetch (1-based count) so the title bar can show
        // WHICH stock is in flight, then a final tick clears the ticker once the universe drains.
        let fundamental = fundamentalSlice(sector: "S", sectorIndexSymbol: nil)
        let warmer = SecurityCacheWarmer(
            provider: OneNameProvider(fundamental: fundamental, live: liveSlice(price: 1)))

        var ticks: [(Int, Ticker?)] = []
        let outcome = await warmer.warm(
            universe: ["AAA", "BBB", "CCC"], onContext: { _ in }, onData: { _, _ in },
            onProgress: { done, _, current, _ in ticks.append((done, current)) })

        #expect(!outcome.abortedOffline)
        // Each name announced in order, paired with its 1-based ordinal.
        #expect(ticks.contains { $0 == (1, "AAA") })
        #expect(ticks.contains { $0 == (2, "BBB") })
        #expect(ticks.contains { $0 == (3, "CCC") })
        #expect(ticks.compactMap { $0.1 } == ["AAA", "BBB", "CCC"])   // order preserved, no extras
        #expect(ticks.last?.1 == nil)                                 // completion clears the ticker
    }

    // MARK: - Progress forwards the in-flight API leg (title bar shows "Considering BBCA insider activity… x/y")

    /// Announces two slow-leg steps then one fast-leg step per name, to prove the warmer forwards the
    /// provider's `onStep` through `onProgress` (same done/total/ticker, varying step).
    private struct SteppingProvider: LegProvider {
        let fundamental: FundamentalSlice
        let live: LiveSlice
        func fundamentals(for t: Ticker, onStep: (@MainActor (String) -> Void)? = nil) async throws -> FundamentalSlice {
            await onStep?("key stats"); await onStep?("insider activity"); return fundamental
        }
        func liveSignals(for t: Ticker, sectorIndexSymbol: String?, onStep: (@MainActor (String) -> Void)? = nil) async throws -> LiveSlice {
            await onStep?("broker flow"); return live
        }
        func marketContext() async throws -> MarketContext { throw SelectionProviderError.noRegimeInputs }
    }

    @Test func progressForwardsTheInFlightStepForTheCurrentTickerThenClearsIt() async {
        let warmer = SecurityCacheWarmer(provider: SteppingProvider(
            fundamental: fundamentalSlice(sector: "S", sectorIndexSymbol: nil), live: liveSlice(price: 1)))

        var ticks: [(Int, Ticker?, String?)] = []
        let outcome = await warmer.warm(
            universe: ["AAA"], onContext: { _ in }, onData: { _, _ in },
            onProgress: { done, _, current, step in ticks.append((done, current, step)) })

        #expect(!outcome.abortedOffline)
        // The per-name announce (step nil) precedes the leg steps, each carrying the SAME ticker + ordinal.
        #expect(ticks.contains { $0 == (1, "AAA", nil) })
        #expect(ticks.contains { $0 == (1, "AAA", "key stats") })
        #expect(ticks.contains { $0 == (1, "AAA", "insider activity") })
        #expect(ticks.contains { $0 == (1, "AAA", "broker flow") })
        #expect(ticks.last?.1 == nil && ticks.last?.2 == nil)   // completion clears both ticker and step
    }

    // MARK: - An intermittent success resets the breaker (a slow-but-alive feed warms fully)

    @Test func aSuccessResetsTheConsecutiveFailureCount() async {
        // Two timeouts, then a success, then two more timeouts must NOT trip a 3-strike breaker —
        // the success in the middle proves the feed is alive, so warming continues.
        let provider = SequencedProvider(results: [
            .failure(Self.timeout), .failure(Self.timeout),
            .success(()), .failure(Self.timeout), .failure(Self.timeout),
        ], contextError: SelectionProviderError.noRegimeInputs)
        let warmer = SecurityCacheWarmer(provider: provider, maxConsecutiveTransportFailures: 3)

        let outcome = await warmer.warm(
            universe: Self.universe(5), onContext: { _ in }, onData: { _, _ in })

        #expect(!outcome.abortedOffline)                // never 3 IN A ROW, so no trip
        #expect(await provider.dataCallCount == 5)      // all five attempted
    }

    // MARK: - Empty universe short-circuits

    @Test func emptyUniverseDoesNothing() async {
        let provider = StubProvider(dataError: Self.timeout, contextError: Self.timeout)
        let warmer = SecurityCacheWarmer(provider: provider)

        let outcome = await warmer.warm(universe: [], onContext: { _ in }, onData: { _, _ in })

        #expect(outcome == SecurityCacheWarmer.Outcome(warmed: 0, total: 0, abortedOffline: false))
        let calls = await provider.dataCallCount
        #expect(calls == 0)
    }

    // MARK: - Two-store warm (Phase 2): the slow slice is cached and the legs compose

    @Test func warmsBothCadenceStoresAndComposesTheLegs() async {
        let fundamental = FundamentalSlice(
            sector: "Sentinel", sharesOutstanding: 0, freeFloatPct: 0, financials: [],
            ttm: TTMFinancials(eps: 0, bookValuePerShare: 0, netIncome: 0, operatingCashFlow: 0,
                               totalAssets: 0, epsGrowthPct: 0, currentRatio: 0, debtToEquity: 0,
                               returnOnEquity: 0),
            sectorIndexSymbol: "IDXSENT", peerComparison: nil, seasonality: nil,
            analystCoverage: nil, governance: nil)
        let live = LiveSlice(price: 4321, dailyBars: [], foreignNetFlow: [],
                             brokerAccumulationSignal: 0, sectorIndexBars: [], marketIndexBars: [],
                             brokerDistribution: nil)
        let warmer = SecurityCacheWarmer(provider: OneNameProvider(fundamental: fundamental, live: live))

        var slowWrites: [(Ticker, FundamentalSlice)] = []
        var composed: [SecurityData] = []
        let outcome = await warmer.warm(
            universe: ["AAA"], onContext: { _ in },
            onFundamentals: { slowWrites.append(($0, $1)) },
            onData: { _, data in composed.append(data) })

        #expect(outcome.warmed == 1)
        #expect(slowWrites.count == 1 && slowWrites.first?.0 == "AAA")   // slow slice cached
        #expect(slowWrites.first?.1.sector == "Sentinel")
        #expect(composed.count == 1)
        #expect(composed.first?.sector == "Sentinel")   // composed: sector from the SLOW leg
        #expect(composed.first?.price == 4321)          // composed: price from the FAST leg
    }

    // MARK: - Intraday cadence (Phase 4): reuse the cached slow leg, fetch only the fast leg

    @Test func intradayPassReusesCachedFundamentalsAndFetchesOnlyTheFastLeg() async {
        let cached = fundamentalSlice(sector: "Cached", sectorIndexSymbol: "IDXC")
        let provider = CountingProvider(
            fundamental: fundamentalSlice(sector: "ShouldNotBeFetched", sectorIndexSymbol: nil),
            live: liveSlice(price: 999))
        let warmer = SecurityCacheWarmer(provider: provider)

        var slowWrites = 0
        var composed: [SecurityData] = []
        let outcome = await warmer.warm(
            universe: ["AAA"], onContext: { _ in },
            onFundamentals: { _, _ in slowWrites += 1 },
            onData: { _, data in composed.append(data) },
            cachedFundamentals: { _ in cached })   // a fresh cached slow leg ⇒ intraday reuse

        #expect(outcome.warmed == 1)
        #expect(await provider.fundamentalsCalls == 0)   // slow leg NOT re-fetched
        #expect(await provider.liveCalls == 1)           // only the fast leg
        #expect(slowWrites == 0)                          // and not re-stored (its age stays meaningful)
        #expect(composed.first?.sector == "Cached")      // composed from the CACHED slow slice
        #expect(composed.first?.price == 999)            // + the FRESH fast price
    }

    @Test func aColdNameFullWarmsBothLegsAndCachesTheSlowSlice() async {
        let provider = CountingProvider(
            fundamental: fundamentalSlice(sector: "Fresh", sectorIndexSymbol: "IDXF"),
            live: liveSlice(price: 1))
        let warmer = SecurityCacheWarmer(provider: provider)

        var slowWrites = 0
        let outcome = await warmer.warm(
            universe: ["AAA"], onContext: { _ in },
            onFundamentals: { _, _ in slowWrites += 1 },
            onData: { _, _ in },
            cachedFundamentals: { _ in nil })   // no fresh cache ⇒ full warm (cold start / stale)

        #expect(outcome.warmed == 1)
        #expect(await provider.fundamentalsCalls == 1)   // both legs fetched
        #expect(await provider.liveCalls == 1)
        #expect(slowWrites == 1)                          // slow slice cached for later reuse
    }
}
