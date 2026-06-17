import Foundation

// In-memory cache of the engine's per-symbol `SecurityData`, filled by the data sweep so the
// Recommendations screen ranks from cache instead of fetching per ticker on tab open (the slow path
// that made the screen sit on "Sizing today's actions…" for minutes). The sweep is the app's single
// fetch path — it already fills the screener + market stores; this is its selection-layer counterpart.
//
// Not persisted: `SecurityData` isn't `Codable`, and the sweep refills the cache on every IDX-session
// pass, so a cold launch warms within the first sweep (the same "show what's cached" contract as the
// screener store). The cached `MarketContext` is captured in the same pass — the engine reads it once.

@MainActor
final class SecurityDataStore {

    /// A cached payload plus when the sweep wrote it (drives the staleness check).
    struct Entry: Sendable {
        let data: SecurityData
        let fetchedAt: Date
    }

    private(set) var entries: [Ticker: Entry] = [:]
    private(set) var context: (value: MarketContext, fetchedAt: Date)?

    /// Default staleness window: an entry older than this is treated as a cache miss. This is the
    /// user's "match the sweep" freshness choice — generous enough to survive an overnight close, after
    /// which the next IDX sweep refills it. Injected at the read site so tests can pin it.
    nonisolated static let defaultMaxAge: TimeInterval = 36 * 60 * 60

    func update(_ data: SecurityData, at now: Date) {
        entries[data.ticker] = Entry(data: data, fetchedAt: now)
    }

    func updateContext(_ context: MarketContext, at now: Date) {
        self.context = (context, now)
    }

    func entry(for ticker: Ticker) -> Entry? { entries[ticker] }

    /// The most recent moment the cache was warmed — the newest `fetchedAt` across the per-symbol
    /// entries and the regime context, or nil when nothing has been cached. While the market is closed
    /// the Recommendations screen labels its ranked picks "as of <this date> · market closed", since the
    /// sweep captures the official close once and then no further sweep runs until the next session.
    func lastWarmedAt() -> Date? {
        [entries.values.map(\.fetchedAt).max(), context?.fetchedAt].compactMap { $0 }.max()
    }

    /// True when `ticker` has an entry written no longer than `maxAge` before `now`.
    func isFresh(_ ticker: Ticker, asOf now: Date, within maxAge: TimeInterval = defaultMaxAge) -> Bool {
        guard let e = entries[ticker] else { return false }
        return now.timeIntervalSince(e.fetchedAt) <= maxAge
    }

    /// An immutable point-in-time read for `CachedDataProvider`: only the still-fresh entries, plus the
    /// regime context if it too is fresh. Built here on the main actor so the provider stays a pure,
    /// isolation-free value the engine can read without actor hops.
    func freshSnapshot(asOf now: Date, within maxAge: TimeInterval = defaultMaxAge)
        -> (data: [Ticker: SecurityData], context: MarketContext?) {
        let fresh = entries.compactMapValues { e in
            now.timeIntervalSince(e.fetchedAt) <= maxAge ? e.data : nil
        }
        let ctx = context.flatMap { now.timeIntervalSince($0.fetchedAt) <= maxAge ? $0.value : nil }
        return (fresh, ctx)
    }
}
