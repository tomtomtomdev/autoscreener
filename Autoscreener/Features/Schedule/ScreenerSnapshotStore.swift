import Foundation

/// Persisted page-1+ result of a single screener, plus the composed Watchlist.
/// Stored as JSON in `~/Library/Application Support/Autoscreener/snapshots/` so
/// app relaunch can render rows instantly while the next scheduled fetch runs.
nonisolated struct ScreenerSnapshot: Codable, Sendable {
    let templateID: String
    let config: ScreenerConfig
    let rows: [ScreenerRow]
    let total: Int?
    let fetchedAt: Date
}

nonisolated struct WatchlistSnapshot: Codable, Sendable {
    let rows: [WatchlistRow]
    let fetchedAt: Date
}

/// Protocol so view models / tests can substitute an in-memory implementation.
nonisolated protocol ScreenerSnapshotStoring: Sendable {
    func loadScreener(templateID: String) async -> ScreenerSnapshot?
    func saveScreener(_ snapshot: ScreenerSnapshot) async
    func loadWatchlist() async -> WatchlistSnapshot?
    func saveWatchlist(_ snapshot: WatchlistSnapshot) async
    /// When false, `save*` is a no-op. Used by callers to suppress writes when
    /// the schedule is `.onDemand` (no persistence requested).
    var persistenceEnabled: Bool { get async }
}

/// File-backed implementation. Lazily creates the snapshots directory under
/// Application Support. Reads are tolerant of missing/corrupt files (return nil).
nonisolated actor ScreenerSnapshotStore: ScreenerSnapshotStoring {
    private let directory: URL
    private let isEnabled: @Sendable () async -> Bool
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL? = nil,
         isEnabled: @escaping @Sendable () async -> Bool = { true }) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = appSupport
                .appendingPathComponent("Autoscreener", isDirectory: true)
                .appendingPathComponent("snapshots", isDirectory: true)
        }
        self.isEnabled = isEnabled
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    var persistenceEnabled: Bool {
        get async { await isEnabled() }
    }

    func loadScreener(templateID: String) async -> ScreenerSnapshot? {
        let url = fileURL(for: templateID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(ScreenerSnapshot.self, from: data)
    }

    func saveScreener(_ snapshot: ScreenerSnapshot) async {
        guard await isEnabled() else { return }
        ensureDirectory()
        let url = fileURL(for: snapshot.templateID)
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func loadWatchlist() async -> WatchlistSnapshot? {
        let url = watchlistURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(WatchlistSnapshot.self, from: data)
    }

    func saveWatchlist(_ snapshot: WatchlistSnapshot) async {
        guard await isEnabled() else { return }
        ensureDirectory()
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: watchlistURL, options: .atomic)
        }
    }

    private func fileURL(for templateID: String) -> URL {
        directory.appendingPathComponent("\(templateID).json")
    }

    private var watchlistURL: URL {
        directory.appendingPathComponent("watchlist.json")
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
    }
}
