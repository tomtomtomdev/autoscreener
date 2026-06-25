import Foundation
import Observation
import OSLog

private let paperLog = Logger(subsystem: "com.tom.tom.tom.Autoscreener", category: "paper-trading")

/// The single source of truth for the paper portfolio: a disk-backed, in-memory
/// `PaperPortfolioState` seeded with 100M IDR. Mirrors `MarketDataStore`'s persistence
/// (DiskModel + atomic write + load-on-init); `version` bumps on every write so the
/// `@Observable`-tracked view refreshes after a fill or a disk load.
///
/// This store only *records* decisions — the allocator (`AllocationEngine`) proposes,
/// the user confirms, and `apply(plan:)` books the fills. Nothing here fetches.
@MainActor
@Observable
final class PaperTradingStore {
    private(set) var state: PaperPortfolioState
    private(set) var version: Int = 0

    @ObservationIgnored private let fileURL: URL?

    /// - Parameters:
    ///   - fileURL: where to persist; `nil` disables persistence (tests/previews).
    ///   - loadFromDisk: hydrate from `fileURL` on init so the portfolio and its P&L
    ///     render immediately on a cold launch. A fresh portfolio (no file) is *seeded*.
    init(fileURL: URL? = PaperTradingStore.defaultFileURL, loadFromDisk: Bool = true) {
        self.fileURL = fileURL
        self.state = .seed
        if loadFromDisk { load() }
    }

    /// Books a confirmed plan: sells first (to free cash), then buys, pricing each fill
    /// through `config.execution` (slippage + side fees). Persists and bumps `version`.
    ///
    /// `theses` (Gate-5 Phase 3) carries the entry rationale per symbol, captured one layer up (the
    /// store never fetches). A thesis is stamped only when a buy *opens* a lot; adds preserve the
    /// original. Defaulted empty so existing callers and the harness stay source-compatible.
    func apply(plan: AllocationPlan, theses: [String: EntryThesis] = [:],
               config: AllocationConfig = .standard, at date: Date = Date()) {
        guard plan.hasTrades else { return }
        let exec = config.execution
        // Sells before buys so proceeds are available to the buys.
        let ordered = plan.lines.sorted { $0.side == .sell && $1.side != .sell }
        for line in ordered {
            let qty = abs(line.deltaShares)
            guard qty > 0 else { continue }
            let slip = line.side == .buy ? (1 + exec.slippagePct) : (1 - exec.slippagePct)
            let feePct = line.side == .buy ? exec.buyFeePct : exec.sellFeePct
            state.apply(side: line.side, symbol: line.symbol, shares: qty,
                        price: line.price * slip, feePct: feePct, date: date,
                        thesis: theses[line.symbol])
        }
        version &+= 1
        persist()
    }

    /// Wipes the portfolio back to its 100M seed (a fresh paper account).
    func reset() {
        state = .seed
        version &+= 1
        persist()
    }

    /// Stamps when the autopilot last auto-rebalanced — the once-per-trading-day guard reads this.
    /// Recorded even when the rebalance booked no trades, so a "nothing to do" day still counts as done.
    func recordAutoRebalance(at date: Date) {
        state.lastAutoRebalanceAt = date
        version &+= 1
        persist()
    }

    // MARK: - Persistence

    private struct DiskModel: Codable { var state: PaperPortfolioState }

    func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(DiskModel(state: state))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            paperLog.error("persist failed: \(String(reflecting: error), privacy: .public)")
        }
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        guard let model = try? JSONDecoder().decode(DiskModel.self, from: data) else {
            paperLog.error("cache decode failed — ignoring stale/corrupt file, keeping seed")
            return
        }
        state = model.state
        version &+= 1
    }

    /// `Application Support/Autoscreener/paper-trading-cache.json`, alongside the other
    /// caches. Nil only if the directory can't be resolved (persistence then off).
    nonisolated static var defaultFileURL: URL? { fileURL(named: "paper-trading-cache.json") }

    private nonisolated static func fileURL(named name: String) -> URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return dir
            .appendingPathComponent("Autoscreener", isDirectory: true)
            .appendingPathComponent(name)
    }
}

// MARK: - Gate-5 holdings gateway (DIP)

/// The paper portfolio IS the live source of held positions for the Gate-5 review (`PositionReviewer`).
/// Mapping the persisted `PaperPosition`s into the engine's boundary DTO keeps the dependency pointing
/// inward — the use case owns `HoldingsProvider`; this infrastructure store implements it. Synchronous
/// and non-throwing (it only reads in-memory state), which legally witnesses the `async throws`
/// requirement; the @MainActor isolation is satisfied by the awaiting caller hopping on.
extension PaperTradingStore: HoldingsProvider {
    func heldPositions() -> [HeldPosition] {
        state.positions.map { symbol, pos in
            HeldPosition(ticker: symbol, shares: pos.shares, avgCost: pos.avgCost, thesis: pos.thesis)
        }
    }
}
