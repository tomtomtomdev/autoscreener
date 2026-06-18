import Foundation
import Observation
import OSLog

private let snapshotLog = Logger(subsystem: "com.tom.tom.tom.Autoscreener", category: "recommendations-snapshot")

/// A disk-backed cache of the LAST SUCCESSFUL Recommendations inbox — the ranked buy picks and the
/// Gate-5 sell-side verdicts as they were displayed, plus the skip note and the "as of close" stamp.
/// Its sole purpose is presentation continuity: on a cold launch (or the first visit before the sweep
/// warms the selection cache) the screen renders this last-known list instead of a spinner, then swaps
/// to live data the instant the fresh load returns (stale-while-revalidate).
///
/// Deliberately separate from `RecommendationsStore` / `ExitDecisionsStore`: those feed the paper-trading
/// allocator and stay in-memory, so persisting *display* state here leaves the allocator's behaviour (and
/// the golden master) untouched. `RecommendationsViewModel` is the only writer — it calls `save(_:)` after
/// a fully successful load — and the only reader, hydrating `snapshot` on init. Mirrors
/// `PaperTradingStore`'s persistence (Codable DiskModel + atomic write + load-on-init).
@MainActor
@Observable
final class RecommendationsSnapshotStore {
    /// The last displayed inbox. Empty until the first successful load persists one (or after a cold
    /// launch with no cache file). `asOf` is non-nil only when the figures were ranked from a closed
    /// market's last-warmed close — it lets the screen keep its "as of <date> · market closed" caption
    /// over the restored list.
    struct Snapshot: Codable {
        var recommendations: [Recommendation] = []
        var decisions: [ExitDecision] = []
        var skipped: [SkippedName] = []
        var asOf: Date? = nil

        var isEmpty: Bool { recommendations.isEmpty && decisions.isEmpty }
    }

    private(set) var snapshot: Snapshot

    @ObservationIgnored private let fileURL: URL?

    /// - Parameters:
    ///   - fileURL: where to persist; `nil` disables persistence (tests/previews).
    ///   - loadFromDisk: hydrate from `fileURL` on init so the last inbox renders immediately on a
    ///     cold launch. With no file (or persistence off) the snapshot starts empty.
    init(fileURL: URL? = RecommendationsSnapshotStore.defaultFileURL, loadFromDisk: Bool = true) {
        self.fileURL = fileURL
        self.snapshot = Snapshot()
        if loadFromDisk { load() }
    }

    /// Replace the cached inbox with the latest successful load and persist it for the next launch.
    /// Called only when both sides loaded for real (not a cold-cache "awaiting" pass and not an error),
    /// so a genuine "nothing to act on today" correctly persists an empty inbox rather than a stale one.
    func save(_ snapshot: Snapshot) {
        self.snapshot = snapshot
        persist()
    }

    // MARK: - Persistence

    private struct DiskModel: Codable { var snapshot: Snapshot }

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(DiskModel(snapshot: snapshot))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            snapshotLog.error("persist failed: \(String(reflecting: error), privacy: .public)")
        }
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        guard let model = try? JSONDecoder().decode(DiskModel.self, from: data) else {
            snapshotLog.error("cache decode failed — ignoring stale/corrupt file, starting empty")
            return
        }
        snapshot = model.snapshot
    }

    /// `Application Support/Autoscreener/recommendations-cache.json`, alongside the other caches.
    /// Nil only if the directory can't be resolved (persistence then off).
    nonisolated static var defaultFileURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return dir
            .appendingPathComponent("Autoscreener", isDirectory: true)
            .appendingPathComponent("recommendations-cache.json")
    }
}
