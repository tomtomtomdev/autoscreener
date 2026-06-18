import Foundation
import OSLog

private let fundamentalLog = Logger(subsystem: "com.tom.tom.tom.Autoscreener", category: "fundamental-store")

// Disk-backed cache of the SLOW cadence leg — the per-symbol `FundamentalSlice` (financials, TTM,
// governance, overlays) that changes at most quarterly. It is the counterpart to `SecurityDataStore`
// (which holds the composed `SecurityData` the engine reads): the warm path writes the slow slice
// here once per close-capture sweep so an intraday-only pass can recompose a name from a FRESH fast
// leg + this CACHED slow leg, instead of re-fetching the ~10 fundamentals requests every sweep.
//
// Persisted (unlike `SecurityDataStore`): the slice is `Codable`, so a cold launch hydrates yesterday's
// fundamentals from disk and recomposes from them + a quick live-price refresh — no full warm. Its own
// (generous) staleness window is independent of `SecurityDataStore`'s: fundamentals stay valid across a
// trading day / weekend, so the close-capture sweep refreshes them while every intraday sweep reuses
// them. Mirrors `RecommendationsSnapshotStore`'s persistence (Codable DiskModel + atomic write +
// decode-safe load-on-init).

@MainActor
final class FundamentalStore {

    /// A cached slow slice plus when the sweep wrote it (drives the staleness check).
    struct Entry: Sendable, Codable {
        let slice: FundamentalSlice
        let fetchedAt: Date
    }

    private(set) var entries: [Ticker: Entry] = [:]

    private let fileURL: URL?

    /// Default staleness window for the slow leg: generous enough to survive a weekend / holiday so the
    /// next close-capture sweep refreshes it, after which an intraday pass keeps reusing it. Fundamentals
    /// move at most quarterly, so a multi-day window never serves a materially stale valuation input.
    nonisolated static let defaultMaxAge: TimeInterval = 4 * 24 * 60 * 60

    /// - Parameters:
    ///   - fileURL: where to persist; `nil` disables persistence (tests/previews).
    ///   - loadFromDisk: hydrate from `fileURL` on init so a cold launch recomposes from yesterday's
    ///     fundamentals. With no file (or persistence off) the store starts empty.
    init(fileURL: URL? = FundamentalStore.defaultFileURL, loadFromDisk: Bool = true) {
        self.fileURL = fileURL
        if loadFromDisk { load() }
    }

    /// Write (or overwrite) a name's slow slice and persist the cache. Write-through so a crash between
    /// sweeps still leaves the last warmed fundamentals on disk for the next cold launch.
    func update(_ slice: FundamentalSlice, for ticker: Ticker, at now: Date) {
        entries[ticker] = Entry(slice: slice, fetchedAt: now)
        persist()
    }

    func entry(for ticker: Ticker) -> Entry? { entries[ticker] }

    /// The still-fresh slow slice for `ticker`, or nil when absent or older than `maxAge` — the signal
    /// an intraday pass uses to decide "reuse the cached fundamentals" vs "this name needs a full warm".
    func freshSlice(for ticker: Ticker, asOf now: Date, within maxAge: TimeInterval = defaultMaxAge)
        -> FundamentalSlice? {
        guard let e = entries[ticker] else { return nil }
        return now.timeIntervalSince(e.fetchedAt) <= maxAge ? e.slice : nil
    }

    /// True when `ticker` has a slow slice written no longer than `maxAge` before `now`.
    func isFresh(_ ticker: Ticker, asOf now: Date, within maxAge: TimeInterval = defaultMaxAge) -> Bool {
        freshSlice(for: ticker, asOf: now, within: maxAge) != nil
    }

    /// The most recent moment the slow leg was warmed — newest `fetchedAt` across entries, or nil when
    /// nothing has been cached.
    func lastWarmedAt() -> Date? { entries.values.map(\.fetchedAt).max() }

    // MARK: - Persistence

    private struct DiskModel: Codable { var entries: [Ticker: Entry] }

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(DiskModel(entries: entries))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            fundamentalLog.error("persist failed: \(String(reflecting: error), privacy: .public)")
        }
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        guard let model = try? JSONDecoder().decode(DiskModel.self, from: data) else {
            fundamentalLog.error("cache decode failed — ignoring stale/corrupt file, starting empty")
            return
        }
        entries = model.entries
    }

    /// `Application Support/Autoscreener/fundamentals-cache.json`, alongside the other caches.
    /// Nil only if the directory can't be resolved (persistence then off).
    nonisolated static var defaultFileURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return dir
            .appendingPathComponent("Autoscreener", isDirectory: true)
            .appendingPathComponent("fundamentals-cache.json")
    }
}
