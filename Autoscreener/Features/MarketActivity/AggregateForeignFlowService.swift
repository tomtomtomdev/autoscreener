import Foundation

/// Market-wide foreign vs. domestic flow — the **top-down regime signal**
/// (`idx-investing-research.md` §2–§3), as distinct from the per-stock
/// validation that `ForeignFlowService` provides. Net foreign *selling* across
/// the whole market is the classic risk-off tell on the IDX.
nonisolated protocol AggregateForeignFlowServicing: Sendable {
    func marketFlow(period: ForeignFlowPeriod) async throws -> ForeignFlow
}

extension AggregateForeignFlowServicing {
    /// Defaults to the single-day window — the daily net-foreign-flow read.
    func marketFlow() async throws -> ForeignFlow {
        try await marketFlow(period: .oneDay)
    }
}

/// The foreign-domestic chart-data endpoint accepts the composite index code in
/// its `{symbol}` slot and returns the same payload shape as a stock, so the
/// aggregate read is a thin specialisation of `ForeignFlowServicing` pinned to
/// IHSG — no separate decoding. (Same endpoint *family* per
/// `idx-regime-data-research.md` §2; not yet confirmed against a live IHSG
/// response, hence `MARKET_TYPE_REGULAR` is carried over from the per-stock call.)
nonisolated final class AggregateForeignFlowService: AggregateForeignFlowServicing {
    /// IDX Composite (IHSG) — the index code used as the foreign-flow symbol.
    static let compositeSymbol = "IHSG"

    private let flowService: any ForeignFlowServicing
    init(flowService: any ForeignFlowServicing) { self.flowService = flowService }

    func marketFlow(period: ForeignFlowPeriod) async throws -> ForeignFlow {
        try await flowService.flow(symbol: Self.compositeSymbol, period: period, marketType: .regular)
    }
}
