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

    /// Counts `data(for:)` calls and throws a configured error from each leg, so the tests can prove
    /// the loop stopped early (call count ≪ universe) instead of marching through every name.
    private actor StubProvider: DataProvider {
        let dataError: Error
        let contextError: Error
        private(set) var dataCallCount = 0

        init(dataError: Error, contextError: Error) {
            self.dataError = dataError
            self.contextError = contextError
        }

        func universe() async throws -> [Ticker] { [] }
        func data(for t: Ticker) async throws -> SecurityData {
            dataCallCount += 1
            throw dataError
        }
        func marketContext() async throws -> MarketContext { throw contextError }
    }

    /// Replays a scripted sequence of per-ticker outcomes (success vs. a specific error), so the
    /// "a success resets the breaker" property can be exercised deterministically.
    private actor SequencedProvider: DataProvider {
        private var results: [Result<Void, Error>]
        private var index = 0
        let contextError: Error
        private(set) var dataCallCount = 0

        init(results: [Result<Void, Error>], contextError: Error) {
            self.results = results
            self.contextError = contextError
        }

        func universe() async throws -> [Ticker] { [] }
        func data(for t: Ticker) async throws -> SecurityData {
            defer { dataCallCount += 1 }
            let result = index < results.count ? results[index] : .failure(URLError(.timedOut))
            index += 1
            switch result {
            case .success:          return Self.barren(t)
            case .failure(let e):   throw e
            }
        }
        func marketContext() async throws -> MarketContext { throw contextError }

        /// A bar-less, financials-less `SecurityData` — enough to stand in for a successful fetch
        /// without recreating the scoring Object Mother (the warmer doesn't inspect its contents).
        static func barren(_ t: Ticker) -> SecurityData {
            SecurityData(
                ticker: t, sector: "Industrials", price: 0, sharesOutstanding: 0, freeFloatPct: 0,
                financials: [],
                ttm: TTMFinancials(eps: 0, bookValuePerShare: 0, netIncome: 0, operatingCashFlow: 0,
                                   totalAssets: 0, epsGrowthPct: 0, currentRatio: 0, debtToEquity: 0,
                                   returnOnEquity: 0),
                dailyBars: [], foreignNetFlow: [], brokerAccumulationSignal: 0,
                sectorIndexBars: [], marketIndexBars: [])
        }
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
            onProgress: { progress.append(($0, $1)) })

        #expect(!outcome.abortedOffline)
        let calls = await provider.dataCallCount
        #expect(calls == 50)                            // breaker stayed shut across all skips
        #expect(progress.last?.0 == 50 && progress.last?.1 == 50)
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
}
