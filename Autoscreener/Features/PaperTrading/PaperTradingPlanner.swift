import Foundation

/// Pure glue between the Tier-A selection output and the `AllocationEngine`: it flattens ranked
/// `Recommendation`s into the allocator's `AllocationCandidate` buy universe and snapshots an
/// `EntryThesis` for each booked buy. No I/O, no observation — shared by the manual paper-trading
/// view model and the headless autopilot so both build the same plan from the same recommendations.
nonisolated enum PaperTradingPlanner {

    /// The buy universe for the allocator: one `AllocationCandidate` per ranked recommendation, carrying
    /// the engine's `conviction` (the ranking key + sizing fallback) and `suggestedWeight` (the primary
    /// sizing signal). `names` supplies a display name per symbol (from the composite watchlist); a name
    /// missing there falls back to its ticker.
    static func candidates(from recommendations: [Recommendation],
                           names: [String: String]) -> [AllocationCandidate] {
        recommendations.map { r in
            AllocationCandidate(symbol: r.ticker,
                                name: names[r.ticker] ?? r.ticker,
                                conviction: r.conviction,
                                suggestedWeight: r.suggestedWeight)
        }
    }

    /// The entry theses to stamp when a plan is booked (Gate-5 Phase 3): one per BUY line whose name is
    /// in the ranked set, reusing the IV / margin-of-safety the engine already computed (no re-fetch). A
    /// buy absent from `recommendations` simply gets no thesis and later reviews on current data alone.
    @MainActor
    static func theses(for plan: AllocationPlan,
                       recommendations: [Ticker: Recommendation],
                       at date: Date) -> [String: EntryThesis] {
        Dictionary(
            plan.lines.lazy
                .filter { $0.side == .buy }
                .compactMap { line -> (String, EntryThesis)? in
                    guard let rec = recommendations[line.symbol] else { return nil }
                    return (line.symbol, EntryThesis(recommendation: rec, entryDate: date))
                },
            uniquingKeysWith: { first, _ in first })
    }
}
