import Foundation

/// Folds the per-screener snapshots in the `ScreenerStore` into the composite
/// Watchlist: union every screener's rows by symbol (accumulating `matchedScreeners`
/// → score), apply the liquidity **veto exclusion**, then rank.
///
/// Veto semantics (`bandar-master.json` "hard-AND for veto rules"): a stock must
/// appear in *every* veto gate (`liquidityFloor` AND `intradayLiquidity`) to survive.
/// Unlike the old behaviour — which kept the row and tagged it "ILLIQUID" — a row
/// failing any **evaluable** veto gate is dropped entirely.
///
/// "Evaluable" guard: a veto gate is only enforced if its snapshot is present in the
/// store. If a gate's fetch failed (no snapshot this generation), excluding on it
/// would wrongly empty the list, so it's skipped and `vetoNotice` warns instead —
/// the same stale-cache protection the tagging path had.
nonisolated enum WatchlistComposer {

    struct Result: Sendable {
        let rows: [WatchlistRow]
        /// Set when a veto gate couldn't be enforced (its snapshot is missing), so
        /// the UI can warn that liquidity filtering wasn't fully applied this cycle.
        let vetoNotice: String?
    }

    static func compose(_ snapshots: [BandarScreenerKind: ScreenerSnapshot]) -> Result {
        // 1) Union rows by symbol, accumulating the matched-screener set.
        var byID: [String: WatchlistRow] = [:]
        for (kind, snapshot) in snapshots {
            for row in snapshot.rows {
                if var existing = byID[row.symbol] {
                    existing.matchedScreeners.insert(kind)
                    byID[row.symbol] = existing
                } else {
                    byID[row.symbol] = WatchlistRow(
                        symbol: row.symbol, name: row.name, matchedScreeners: [kind])
                }
            }
        }

        // 2) Veto exclusion over the gates we can actually evaluate.
        let evaluableVeto = BandarScreenerKind.vetoKinds.filter { snapshots[$0] != nil }
        let survivors = byID.values.filter { row in
            evaluableVeto.allSatisfy { row.matchedScreeners.contains($0) }
        }

        // 3) Rank: score desc, then symbol asc.
        let ranked = survivors.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.symbol < b.symbol
        }

        return Result(rows: ranked, vetoNotice: notice(skipped: BandarScreenerKind.vetoKinds.subtracting(evaluableVeto)))
    }

    private static func notice(skipped: Set<BandarScreenerKind>) -> String? {
        guard !skipped.isEmpty else { return nil }
        let names = skipped.map(\.displayName).sorted()
        return "Liquidity veto not enforced (stale/missing cache): \(names.joined(separator: ", "))"
    }
}
