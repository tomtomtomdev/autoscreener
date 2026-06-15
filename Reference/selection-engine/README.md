# Selection engine — reference spec (not in the build target)

Opus-4.8 reference spec for the IDX stock-selection engine + backtester. **These files are NOT
added to any Xcode target** — they live here only so the integration plan is reproducible after a
context clear. Do not edit them as the working copy.

- `StockSelectionEngine.swift` — config-driven selection pipeline (regime → gates → MoS → scorers →
  modifiers → composite → constrained sizing). Plugs in via the `DataProvider` protocol.
- `BacktestHarness.swift` — point-in-time replay + config sweep, via the `HistoricalDataSource`
  protocol.

The integration plan and canonical build order live in **`/INTEGRATION.md`** (repo root). Phase 0.1
of that plan is when these get added to the actual app target.
