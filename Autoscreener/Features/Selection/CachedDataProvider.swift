import Foundation

// Read-only `DataProvider` backed by the sweep-filled `SecurityDataStore`: the Recommendations engine
// reads its per-symbol data from cache instead of fetching live on tab open (the slow path that left
// the screen on "Sizing today's actions…"). A pure value — the caller snapshots the fresh cache once
// on the main actor and hands the immutable maps in, so the engine reads with no actor hops, no network.
//
// Cache-miss contract (the user's "show cached only, never fetch" choice): a name not in the snapshot
// throws `SelectionProviderError.notCached`, which the engine treats as a SKIP — it never falls back to
// a live fetch. A fully cold cache (no context, or no fresh entries) is detected one level up, in
// `AppDependencies.todaysPicks` / `reviewPositions`, which short-circuit to a "waiting for the sweep"
// outcome rather than running the engine against an empty cache.

struct CachedDataProvider: DataProvider {
    /// The still-fresh per-symbol payloads from the latest sweep (already staleness-filtered by the store).
    let cached: [Ticker: SecurityData]
    /// The regime context captured in that same sweep; nil ⇒ cold ⇒ `marketContext()` refuses to score.
    let context: MarketContext?
    /// The candidate universe to rank — the REQUESTED symbols (watchlist / held), not just the cached
    /// keys, so names the sweep hasn't reached yet surface as `notCached` skips instead of vanishing.
    let tickers: [Ticker]

    func universe() async throws -> [Ticker] { tickers }

    func data(for t: Ticker) async throws -> SecurityData {
        guard let data = cached[t] else { throw SelectionProviderError.notCached(t) }
        return data
    }

    func marketContext() async throws -> MarketContext {
        guard let context else { throw SelectionProviderError.noRegimeInputs }
        return context
    }
}
