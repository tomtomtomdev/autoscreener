import Foundation

/// Bounds the per-symbol cache-warming fan-out so a flaky network can't hang the sweep.
///
/// Background: `AppDependencies.warmSecurityCache` warms `SecurityDataStore` by fetching each
/// watchlist ∪ held name's `SecurityData` serially through the shared throttle (~15 requests per
/// ticker, ~1.25s apart). When the connection drops mid-sweep, every request burns its full
/// timeout × retry budget (~90s) and the old loop swallowed the failure with `try?` and marched
/// through the WHOLE universe — tens of minutes during which `DataSweepCoordinator.isSweeping`
/// stayed true, freezing the title bar on "Fetching 20/20" and stranding the Recommendations screen
/// on "waiting for the data sweep".
///
/// The fix is an **offline circuit breaker**: after `maxConsecutiveTransportFailures` per-ticker
/// fetches fail in a row with a *transport* error (timeout / connection lost / 5xx), warming stops —
/// the feed is unreachable, so grinding through the rest of the universe is futile. Crucially the
/// breaker keys off *consecutive* failures, so a healthy-but-slow warm (each success resets the
/// counter) runs to completion however long it takes; only a genuine outage trips it. A *valuation*
/// skip (no price / missing field — an expected, name-specific outcome) is neutral: it neither
/// resets the counter nor counts as a strike. Single hung requests are already bounded by the
/// URLSession resource timeout; task teardown is honoured via `Task.isCancelled`.
///
/// It writes each landed entry through the `onData`/`onContext` sinks as it goes (partial warming
/// still populates the cache) and reports `onProgress` so the title bar can show real warming
/// progress instead of a frozen screener count.
struct SecurityCacheWarmer {
    let provider: LegProvider
    /// Consecutive transport failures that mean "the feed is down → stop". Default 3 — high enough
    /// not to trip on a brief blip mid-warm, low enough to bail an outage in a few requests.
    var maxConsecutiveTransportFailures: Int = 3

    struct Outcome: Equatable {
        var warmed: Int
        var total: Int
        /// The breaker tripped — the feed looked unreachable, so warming stopped early.
        var abortedOffline: Bool
    }

    /// Warm `universe` through the provider, writing each landed entry to the sinks. Runs on the main
    /// actor (the sinks touch `@MainActor` stores); the `await`s hop to the provider actor and back.
    @MainActor
    func warm(universe: [Ticker],
              onContext: (MarketContext) -> Void,
              onFundamentals: (Ticker, FundamentalSlice) -> Void = { _, _ in },
              onData: (Ticker, SecurityData) -> Void,
              cachedFundamentals: (Ticker) -> FundamentalSlice? = { _ in nil },
              onProgress: (_ done: Int, _ total: Int, _ current: Ticker?) -> Void = { _, _, _ in }) async -> Outcome {
        let total = universe.count
        guard total > 0 else { return Outcome(warmed: 0, total: 0, abortedOffline: false) }
        onProgress(0, total, nil)

        var consecutiveFailures = 0

        // Regime context first — the engine can't rank without it. A transport failure here is one
        // strike toward the breaker (not an abort); the per-ticker loop may still recover.
        do {
            onContext(try await provider.marketContext())
        } catch {
            if Self.isTransportFailure(error) { consecutiveFailures += 1 }
        }

        var warmed = 0
        for (index, t) in universe.enumerated() {
            if Task.isCancelled { break }                          // sweep torn down → stop, don't churn
            if consecutiveFailures >= maxConsecutiveTransportFailures {
                // The feed is unreachable — bail instead of burning ~90s per remaining name.
                return Outcome(warmed: warmed, total: total, abortedOffline: true)
            }
            // Announce the name being fetched (1-based, so the count matches the named stock's
            // ordinal) so the title bar can show "Warming BBCA 3/20" — which stock is in flight,
            // not just a bare counter.
            onProgress(index + 1, total, t)
            do {
                if let cached = cachedFundamentals(t) {
                    // INTRADAY reuse: the slow leg is still fresh in cache → fetch ONLY the fast leg
                    // (~4 requests) and recompose against the cached fundamentals. No fundamentals
                    // re-fetch, and no re-store (its age stays meaningful so the close-capture sweep
                    // still knows when to refresh it).
                    let live = try await provider.liveSignals(for: t, sectorIndexSymbol: cached.sectorIndexSymbol)
                    onData(t, StockbitDataProvider.compose(t, fundamentals: cached, live: live))
                } else {
                    // FULL warm: a cold/stale name, or a close-capture refresh. Fetch both cadence legs
                    // (same total request count as the old single `data(for:)`), cache the slow slice for
                    // later intraday reuse, and compose. All-or-nothing per name: a throw in either leg
                    // writes neither store, exactly as the old single-fetch did.
                    let fundamentals = try await provider.fundamentals(for: t)
                    let live = try await provider.liveSignals(for: t, sectorIndexSymbol: fundamentals.sectorIndexSymbol)
                    onFundamentals(t, fundamentals)
                    onData(t, StockbitDataProvider.compose(t, fundamentals: fundamentals, live: live))
                }
                warmed += 1
                consecutiveFailures = 0                            // a success proves the feed is alive
            } catch {
                // Transport failures count toward the breaker; valuation skips (no price / missing
                // field) are expected, name-specific outcomes — neutral, neither reset nor strike.
                if Self.isTransportFailure(error) { consecutiveFailures += 1 }
            }
        }
        // The universe drained cleanly — report completion and clear the in-flight ticker so the bar
        // shows a bare "Warming n/n" instead of leaving the last name's label lingering.
        onProgress(total, total, nil)
        return Outcome(warmed: warmed, total: total, abortedOffline: false)
    }

    /// True for errors that mean "the feed is unreachable" — URL-layer transport failures (timeout,
    /// connection lost, DNS, …) and exhausted-retry 5xx/timeout server statuses. A deliberate
    /// `.cancelled`, a 4xx (bad param / not found), or an auth error is request-specific, not an
    /// outage, so it never counts toward the offline breaker.
    static func isTransportFailure(_ error: Error) -> Bool {
        if let urlError = error as? URLError { return urlError.code != .cancelled }
        if case APIError.transport = error { return true }
        if case let APIError.http(status, _) = error { return status >= 500 || status == 408 || status == 429 }
        return false
    }
}
