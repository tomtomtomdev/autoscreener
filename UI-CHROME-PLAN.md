# UI Chrome Plan — remove per-screen refresh + global fetch-status bar

Replace the scattered per-screen refresh controls with a single **global fetch/API status indicator**
centred in the macOS window title bar. The continuous `DataSweepCoordinator` loop already keeps data
fresh, so manual refresh is redundant chrome; the status bar makes the *automatic* fetching legible.

---

## Status & how to resume (READ FIRST) — locked 2026-06-14

**BUILT & COMMITTED 2026-06-14 — branch `feat/ui-chrome-global-fetch-status` (off `main`@`0bd1b1c`), UNPUSHED.**
All 7 §4 steps done; decisions 1/2/3 below all honoured.
- **Step 1** — `Features/Main/FetchStatus.swift` (pure `enum` + `resolve(…)` + `displayLabel`/`tint`/`showsSpinner`),
  `FetchStatusTests` (12 cases, precedence asserted by case-equality). Green.
- **Step 2** — `Features/Main/GlobalFetchStatusView.swift` (thin renderer, constructor-injected coordinator +
  market store, `globalfetchstatus` a11y id/value).
- **Step 3** — `MainSidebarView.detail` now wraps one shared `NavigationStack` with the `.principal`
  `GlobalFetchStatusView()`; the per-screen `NavigationStack` was removed from `ScreenerView`/`WatchlistView`/
  `MarketsView`/`TodaysPicksView`/`PositionsReviewView` (titles/toolbars/`.searchable`/`.navigationDestination`
  kept, re-homed onto the surviving root view). PaperTrading/AppSettings never had their own stack. Primary
  (shared-stack) approach used — the per-screen `.globalFetchStatusToolbar()` fallback was NOT needed.
- **Step 4** — Refresh `Button` deleted from Screener/Watchlist; `.refreshable` deleted from
  Markets/TodaysPicks/PositionsReview. Dead `ScreenerViewModel.refresh()` removed (no callers left);
  `WatchlistViewModel.refresh()` KEPT (still used by `WatchlistTests`).
- **Step 5** — `TodaysPicksView` + `PositionsReviewView` got
  `.onChange(of: AppDependencies.shared.marketDataStore.lastSweepAt) { _,_ in Task { await vm.load(force: true) } }`.
- **Step 6** — `AutoscreenerUITests/GlobalFetchStatusUITests.swift` (asserts `globalfetchstatus` on
  Watchlist + Today's Picks, and `Refresh` button absent; multi-display `XCTSkipIf` guard). **Runner could
  not bootstrap on this dev box** (`Early unexpected exit … signal kill before establishing connection` — the
  standing env caveat, NOT an assertion failure). App was launched directly under `-UITestFixtures` and stays
  up (no launch crash from the shared-stack refactor); kept as committed proof for CI.
- **Step 7** — full `AutoscreenerTests` TEST SUCCEEDED (incl. the 12 new `FetchStatus` cases);
  `SelectionEngineCharacterizationTests` golden master byte-for-byte (no engine code touched).

**Original plan (kept for reference):** Planning was locked; build not started. Decisions below were chosen by the user.

**Decisions (locked):**
1. **Placement = native title-bar centre.** A `ToolbarItem(placement: .principal)` centred in the macOS
   title bar. Achieved by giving the split-view *detail* column **one shared `NavigationStack`** and
   removing the per-screen `NavigationStack` wrappers (screens keep their `.navigationTitle` / their own
   `.toolbar` items / `.searchable`). Fallback if the shared stack misbehaves: a `.globalFetchStatusToolbar()`
   view-modifier applied per screen (see §3, Risk R1).
2. **Re-run model = auto-reload on sweep complete.** The two engine-backed screens that do NOT route
   through the coordinator — **Today's Picks** and **Positions to Review** — re-run their engine source when
   a new global sweep lands (observe `MarketDataStore.lastSweepAt`), so dropping their refresh control does
   not strand stale output. Coordinator-backed screens (screeners, Watchlist, Markets) already refresh on
   the continuous loop.
3. **Scope = all fetch-backed screens.** Remove the refresh control from screeners, Watchlist, Today's
   Picks, Markets, and Positions to Review. The global status bar becomes the single fetch surface.

**Workflow (per CLAUDE.md):** test-first. SwiftUI screen work → consult `swiftui-architecture` (+ `macos-development`
for the toolbar/title-bar specifics) before coding. UI verified by **XCUITest under `-UITestFixtures`**
(give every assertable view an `.accessibilityIdentifier`); honour the multi-display `XCTSkipIf` guard.
NOTE the standing environmental caveat: the XCUITest runner sometimes can't start on this dev box
("Timed out while enabling automation mode") — trust the unit suite, keep the XCUITest as committed proof.

---

## 1. Current state (verified 2026-06-14)

**Refresh controls to remove:**
| Screen | File:line | Control | Calls |
|---|---|---|---|
| Screeners (×20) | `Features/Screener/ScreenerView.swift:70` | toolbar `Button` | `vm.refresh()` → `coordinator.refreshNow()` |
| Watchlist | `Features/Watchlist/WatchlistView.swift:58` | toolbar `Button` | `vm.refresh()` → `coordinator.refreshNow()` |
| Today's Picks | `Features/Selection/TodaysPicksView.swift:39` | `.refreshable` | `vm.load(force: true)` (engine) |
| Markets | `Features/Markets/MarketsView.swift:79` | `.refreshable` | `regime.load(force:)` + `marketQuotes.load(force:)` → `coordinator.refreshNow()` |
| Positions to Review | `Features/Selection/PositionsReviewView.swift:39` | `.refreshable` | `vm.load(force: true)` (engine) |

**Keep on every screen:** the `.task { … }` auto-load, the loading spinner, and the "as of HH:mm" stamp.

**Status data already published (no new fetching needed)** — `DataSweepCoordinator`
(`Features/Screener/DataSweepCoordinator.swift`), `@Observable`, on `AppDependencies.shared.dataSweepCoordinator`:
- `isSweeping: Bool`, `loadedScreenerCount: Int`, `totalScreenerCount: Int` (= 20),
  `lastError: String?`, `paywallMessage: String?`.
- `MarketDataStore.lastSweepAt: Date?` (+ `version: Int`).

**Top-bar structure today:** `MainSidebarView` = `NavigationSplitView { sidebar } detail: { detailView }`.
No window toolbar, no `.principal` placement anywhere. Each detail view wraps itself in its **own**
`NavigationStack` (e.g. `ScreenerView:20`) and sets `.navigationTitle` / its own toolbar / `.searchable`.

---

## 2. Target design

```
┌─ Autoscreener ──────────[ Fetching 7/20 ⟳ ]──────────────┐   ← .principal toolbar item, centred
│ Sidebar │  <detail content for the selected SidebarItem> │
└─────────┴────────────────────────────────────────────────┘
```

- **`FetchStatus` (pure, testable)** — maps coordinator/store state → a render model + label, with a fixed
  precedence so the bar never lies:
  ```
  sweeping            → .fetching(done, total)   "Fetching 7/20…"   (spinner)
  else lastError      → .error(message)          red
  else paywallMessage → .paywall(message)        orange
  else lastSweepAt    → .updated(date)           "Updated 14:32"
  else                → .idle                    "—"
  ```
  Live in a new `Features/Main/FetchStatus.swift` as a pure `enum` + `static func resolve(isSweeping:
  loaded:total:lastError:paywall:lastSweepAt:) -> FetchStatus` and a `displayLabel`. No SwiftUI import.
- **`GlobalFetchStatusView`** (`Features/Main/GlobalFetchStatusView.swift`) — thin renderer: reads the
  shared coordinator + market store, calls `FetchStatus.resolve(…)`, renders label + conditional spinner /
  colour. a11y: `.accessibilityIdentifier("globalfetchstatus")` (+ value = the label) so XCUITest can read
  the current state.

---

## 3. Navigation refactor (Decision 1)

Centralise the title bar so the principal item shows on every screen:
- In `MainSidebarView`, wrap the `detail:` builder once: `NavigationStack { detailView }
  .toolbar { ToolbarItem(placement: .principal) { GlobalFetchStatusView() } }`.
- Remove the `NavigationStack { … }` wrapper from each detail view (`ScreenerView`, `WatchlistView`,
  `MarketsView`, `TodaysPicksView`, `PositionsReviewView`, `PaperTradingView`, …). Keep each screen's
  `.navigationTitle`, `.toolbar`(non-refresh items), and `.searchable` — they now attach to the shared stack.

**Risk R1 — shared-stack regressions.** Screens that push internally (e.g. a StockDetail `NavigationLink`)
must still navigate; a single shared stack *supports* pushes, but each screen must be re-verified. If any
screen breaks, fall back to the per-screen modifier `.globalFetchStatusToolbar()` (a `ViewModifier` adding
the `.principal` item) applied to each screen's existing `NavigationStack` — no central refactor, slight
duplication. Audit every `SidebarItem` arm before deleting its `NavigationStack`.

**Risk R2 — `.navigationTitle` vs `.principal` on macOS.** `.navigationTitle` drives the window title;
`.principal` is the centred toolbar region — they coexist. Verify the title still renders and the principal
item is centred (not crowded by per-screen `.toolbar` buttons like Paper Trading's Generate/Reset).

---

## 4. Build order (test-first)

1. **`FetchStatus` (pure) + tests.** New `Features/Main/FetchStatus.swift`. Unit-test (`FetchStatusTests`,
   Swift Testing) each state and the precedence order (sweeping wins over a stale error; error over paywall;
   paywall over updated; updated over idle). *Red → green first — this is the cheap, fully-deterministic core.*
2. **`GlobalFetchStatusView`.** Thin renderer over `FetchStatus.resolve(…)`; `globalfetchstatus` a11y id.
   (View is glue; covered by the pure tests + the XCUITest in step 6.)
3. **Navigation refactor (§3).** Add the shared `NavigationStack` + `.principal` item in `MainSidebarView`;
   strip per-screen `NavigationStack`s. Build + cold-launch under `-UITestFixtures`; eyeball each screen.
4. **Remove refresh controls (Decision 3).** Delete the `Button` from `ScreenerView`/`WatchlistView`; delete
   `.refreshable` from `MarketsView`/`TodaysPicksView`/`PositionsReviewView`. Keep auto-load + spinner +
   "as of" stamp. If a `vm.refresh()` becomes unused after removal, leave it (harmless) or delete if dead —
   check `WatchlistViewModel.refresh` / `ScreenerViewModel.refresh` callers first.
5. **Auto-reload on sweep (Decision 2).** In `TodaysPicksView` and `PositionsReviewView`, add
   `.onChange(of: marketStore.lastSweepAt) { _, _ in Task { await vm.load(force: true) } }` (read
   `AppDependencies.shared.marketDataStore`). The `load(force:)` path is already unit-tested
   (`TodaysPicksViewModelTests` / `PositionReviewViewModelTests`); the trigger is view glue, proven by the
   XCUITest in step 6. *(Optional cleaner seam: inject a `lastSweepAt` signal into the VM and unit-test the
   re-run — only if the view-level `.onChange` proves flaky.)*
6. **XCUITest (`-UITestFixtures`).** Assert `globalfetchstatus` exists on ≥2 screens; assert the old refresh
   controls are **absent** (the `arrow.clockwise` buttons no longer queryable). Multi-display `XCTSkipIf`
   guard. Honour the env caveat (runner may not start here — keep as committed proof, trust unit suite).
7. **Full bundle + golden master.** `xcodebuild test -scheme Autoscreener -destination 'platform=macOS'
   -only-testing:AutoscreenerTests` → TEST SUCCEEDED; `SelectionEngineCharacterizationTests` byte-for-byte
   (this change is pure UI/chrome — it must not touch the engine).

---

## 5. Out of scope / open

- No change to the sweep cadence or the coordinator's fetching logic — chrome only.
- Paper Trading keeps its `Generate plan` / `Reset` toolbar buttons (those aren't refresh).
- A "force a sweep now" affordance is intentionally dropped (the continuous loop covers it). If users miss
  it, a single global refresh action could later be added *next to* the status item — not planned now.
