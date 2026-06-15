import Foundation
import Observation
import OSLog

private let storeLog = Logger(subsystem: "com.tom.tom.tom.Autoscreener", category: "screener-store")

/// One screener's captured result: the template config (filters/sequence/columns)
/// and every row the sweep collected, plus when it landed. `config` is required so
/// a per-tab `ScreenerViewModel` can render the right columns from a cached snapshot
/// without re-fetching the template. All members are already `Codable`, so the whole
/// cache round-trips to disk for free.
nonisolated struct ScreenerSnapshot: Codable, Sendable {
    let config: ScreenerConfig
    let rows: [ScreenerRow]
    let fetchedAt: Date
}

/// The single source of truth for screener data: a disk-backed, in-memory cache of
/// the latest snapshot per `BandarScreenerKind`. The sweep coordinator is the only
/// writer; every UI surface (each screener tab + the composite Watchlist) reads from
/// here, so nothing else touches the network.
///
/// `version` bumps on every write so observers can cheaply memoise derived work
/// (e.g. the Watchlist composite) instead of recomputing on every SwiftUI render.
/// Reading `version`/`snapshots` is `@Observable`-tracked, so views refresh as each
/// screener lands during a sweep (progressive fill-in) and after a disk load.
@MainActor
@Observable
final class ScreenerStore {
    private(set) var snapshots: [BandarScreenerKind: ScreenerSnapshot] = [:]
    private(set) var lastSweepAt: Date?
    /// Monotonically increasing write counter — see type doc.
    private(set) var version: Int = 0

    @ObservationIgnored private let fileURL: URL?

    /// - Parameters:
    ///   - fileURL: where to persist; `nil` disables persistence (tests/previews).
    ///   - loadFromDisk: when true, hydrate from `fileURL` on init so cached rows
    ///     render immediately on a cold launch (including while the market is closed).
    init(fileURL: URL? = ScreenerStore.defaultFileURL, loadFromDisk: Bool = true) {
        self.fileURL = fileURL
        if loadFromDisk { load() }
    }

    func snapshot(for kind: BandarScreenerKind) -> ScreenerSnapshot? { snapshots[kind] }

    /// Writes one screener's snapshot and bumps `version`. Called once per screener
    /// as a sweep advances, so the Watchlist composite fills in progressively.
    func apply(_ snapshot: ScreenerSnapshot, for kind: BandarScreenerKind) {
        snapshots[kind] = snapshot
        version &+= 1
    }

    /// Stamps the sweep-complete time and flushes the whole cache to disk.
    func markSweepComplete(at date: Date) {
        lastSweepAt = date
        persist()
    }

    // MARK: - Persistence

    /// On-disk shape: snapshots keyed by `kind.rawValue` (a stable String), so adding
    /// or removing a kind never invalidates an existing file — unknown keys are
    /// dropped and missing kinds simply self-heal on the next sweep.
    private struct DiskModel: Codable {
        var lastSweepAt: Date?
        var snapshots: [String: ScreenerSnapshot]
    }

    func persist() {
        guard let fileURL else { return }
        let model = DiskModel(
            lastSweepAt: lastSweepAt,
            snapshots: Dictionary(uniqueKeysWithValues: snapshots.map { ($0.key.rawValue, $0.value) }))
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(model)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            storeLog.error("persist failed: \(String(reflecting: error), privacy: .public)")
        }
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        guard let model = try? JSONDecoder().decode(DiskModel.self, from: data) else {
            storeLog.error("cache decode failed — ignoring stale/corrupt file")
            return
        }
        var restored: [BandarScreenerKind: ScreenerSnapshot] = [:]
        for (key, snapshot) in model.snapshots {
            // Tolerate a key that no longer maps to a kind (kind renamed/removed).
            guard let kind = BandarScreenerKind(rawValue: key) else { continue }
            restored[kind] = snapshot
        }
        snapshots = restored
        lastSweepAt = model.lastSweepAt
        version &+= 1
    }

    /// `Application Support/Autoscreener/screener-cache.json`. Nil only if the
    /// directory can't be resolved (then persistence is silently disabled).
    nonisolated static var defaultFileURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return dir
            .appendingPathComponent("Autoscreener", isDirectory: true)
            .appendingPathComponent("screener-cache.json")
    }
}
