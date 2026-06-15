import Foundation
import Observation
import OSLog

private let marketStoreLog = Logger(subsystem: "com.tom.tom.tom.Autoscreener", category: "market-store")

/// The single source of truth for the Markets screen: a disk-backed, in-memory cache
/// of the latest price snapshot per symbol plus the synthesised market-regime read.
/// The `DataSweepCoordinator` is the only writer; `MarketsView` (via its thin
/// `MarketQuotesViewModel` / `RegimeViewModel` projections) reads from here, so the
/// Markets screen never touches the network itself — exactly the arrangement
/// `ScreenerStore` gives the screeners.
///
/// `version` bumps on every write so observers can cheaply memoise derived work, and
/// reading `quotes`/`regimeRead`/`version` is `@Observable`-tracked, so the banner and
/// rows fill in progressively as a sweep lands and after a disk load.
@MainActor
@Observable
final class MarketDataStore {
    private(set) var quotes: [String: CommodityQuote] = [:]
    private(set) var regimeRead: RegimeRead?
    private(set) var lastSweepAt: Date?
    /// Monotonically increasing write counter.
    private(set) var version: Int = 0

    @ObservationIgnored private let fileURL: URL?

    /// - Parameters:
    ///   - fileURL: where to persist; `nil` disables persistence (tests/previews).
    ///   - loadFromDisk: when true, hydrate from `fileURL` on init so cached quotes and
    ///     the last regime read render immediately on a cold launch (incl. while closed).
    init(fileURL: URL? = MarketDataStore.defaultFileURL, loadFromDisk: Bool = true) {
        self.fileURL = fileURL
        if loadFromDisk { load() }
    }

    /// Merges freshly-fetched quotes over the existing ones, so a symbol that failed
    /// this round keeps its prior value (mirrors the old `MarketQuotesViewModel`).
    func applyQuotes(_ fetched: [String: CommodityQuote]) {
        guard !fetched.isEmpty else { return }
        quotes.merge(fetched) { _, new in new }
        version &+= 1
    }

    /// Writes the latest synthesised regime read.
    func apply(regimeRead: RegimeRead) {
        self.regimeRead = regimeRead
        version &+= 1
    }

    /// Stamps the sweep-complete time and flushes the whole cache to disk.
    func markSweepComplete(at date: Date) {
        lastSweepAt = date
        persist()
    }

    // MARK: - Persistence

    private struct DiskModel: Codable {
        var lastSweepAt: Date?
        var quotes: [String: CommodityQuote]
        var regimeRead: RegimeRead?
    }

    func persist() {
        guard let fileURL else { return }
        let model = DiskModel(lastSweepAt: lastSweepAt, quotes: quotes, regimeRead: regimeRead)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(model)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            marketStoreLog.error("persist failed: \(String(reflecting: error), privacy: .public)")
        }
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        guard let model = try? JSONDecoder().decode(DiskModel.self, from: data) else {
            marketStoreLog.error("cache decode failed — ignoring stale/corrupt file")
            return
        }
        quotes = model.quotes
        regimeRead = model.regimeRead
        lastSweepAt = model.lastSweepAt
        version &+= 1
    }

    /// `Application Support/Autoscreener/market-cache.json`, alongside the screener
    /// cache. Nil only if the directory can't be resolved (then persistence is off).
    nonisolated static var defaultFileURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return dir
            .appendingPathComponent("Autoscreener", isDirectory: true)
            .appendingPathComponent("market-cache.json")
    }
}
