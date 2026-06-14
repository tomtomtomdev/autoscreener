# Autoscreener — Spec

macOS-native client for running Stockbit screeners against the IDX market. Logs in to `exodus.stockbit.com`, manages access/refresh tokens transparently, lets the user describe a screen, fires it, and renders the results in a sortable table.

Target: macOS 15.0+ (Sequoia). Stack: SwiftUI, `@Observable`, `URLSession` async/await, Keychain, no third-party deps.

---

## 1. Scope (v1)

- [x] **Settings → Account**: username + password `TextField`s, "Sign in" button. Credentials never persisted in plaintext; tokens stored in Keychain.
- [x] **Auth pipeline**: `POST /login/v6/username` → store access + refresh JWTs → pre-flight refresh on `expired_at` proximity → 401 backstop via `POST /login/refresh` → silent retry.
- [x] **New-device MFA**: detect `multi_factor` envelope, walk `/mfa/verification/v1/challenge/{start,otp/send,otp/verify}` then `/login/v6/new-device/verify` — sequential email → phone OTPs, auto-sent on the server's `default_channel`.
- [x] **Screener run**: fifteen canned screener templates (Bandar Accumulating, Bandar Above MA20, Bandar Shift Today, Accum/Dist Positive, 1M / 6M / 3M Net Foreign Flow, Foreign Buy Streak ≥5, Fresh Foreign Buy, Frequency Spike, Volume Spike, Above 50MA, Above 200MA, Liquidity Floor, Intraday Liquidity) — `GET /screener/templates/{id}` for page 1, `POST /screener/templates` with `save:"0"` for pages ≥ 2.
- [x] **Watchlist (composite)**: union of all twenty screeners' rows, scored by per-rule weight (`bandar-master.json`), sorted desc. The two liquidity rules are *veto gates*: stocks missing from either evaluable gate are **excluded** from the composite entirely (hard-AND), not tagged. The 20 per-screener screens are **no longer listed in the sidebar** (sweep + data unchanged); instead each Watchlist row shows a tinted **screener-icon column** to the right of the score — one icon per *signal* screener it matched, the two liquidity gates omitted since they hold on every surviving row (§7.4).
- [x] **Continuous market-hours sweep + disk cache** (§15): a single `DataSweepCoordinator` is the whole app's only fetch path. One throttled sweep (1–1.5 s between every request) fills two disk-backed stores — `ScreenerStore` (the 20 screeners) and `MarketDataStore` (Markets quotes + the regime read, §17). Open → full refresh every 5–10 min; closed → only the around-the-clock legs (global/commodity/FX) refresh every 20–30 min while the IDX-session legs stay frozen. The Watchlist and the Markets screen (and the now-unlisted per-screener views, still reachable in code) read from these caches — on a closed market or cold relaunch they render the last persisted snapshot with no network. Refresh forces an immediate full sweep regardless of session.
- [x] **Recommendations** (unified): the buy-side picks and the Gate-5 sell-side review are merged into one ranked "Recommendations" inbox (EXIT→TRIM→BUY→HOLD), the **default landing**. Supersedes the separate, hidden "Today's Picks" + "Positions to Review" screens. The composite Watchlist (the upstream radar) is rendered as a **section directly beneath the inbox on the same screen** (one shared scroll) — the two were merged into a single surface; "Watchlist" is no longer its own sidebar tab (§7.4/§15).
- [x] **Results table**: SwiftUI `Table` with sortable columns (symbol, name, + 1–2 metric columns depending on the screener's `sequence`).
- [x] **Pagination**: increment `page` in the request body for "Load more".
- [x] **Stock-code search** (§7.3): a `.searchable` toolbar field on the Liquidity Floor, Intraday Liquidity, and Watchlist tabs filters rows by ticker (case-insensitive substring on the symbol). On the two paginated screener tabs, entering a term auto-loads all remaining pages first, so a match is never hidden behind lazy pagination; the Watchlist already holds the complete set.
- [x] **Network log panel** in Settings — live request/response trace with redaction of `password`, `otp`, `*_token`, `authorization`.
- [x] **Markets — regime banner + every-row price list** (§17): the Markets screen leads with the **Market Regime banner** (risk-on / neutral / risk-off read; tap → full factor breakdown) beside a **Global** section of world indices (11: S&P 500, Dow Jones, Nasdaq, FTSE 100, DAX, CAC 40, Nikkei 225, Hang Seng, KOSPI, Shanghai, Straits Times), then the composite (IHSG) over indices on the left with **Commodities** (13: Crude Oil, Brent, Natural Gas, Newcastle Coal, Palm Oil, Gold, Silver, Nickel, Copper, Aluminium, Tin, Zinc, Rubber) over **Currencies** (5: USD/IDR, SGD/IDR, EUR/IDR, AUD/IDR, CNY/IDR) on the right, then the IDX-IC sectors as a single full-width column — **every row** showing a live last-price + signed % change from `GET /emitten/{symbol}/info` (the same snapshot serves global/indices/sectors as commodities). Loaded on appear, pull-to-refresh, per-symbol failure tolerated. Tapping a chartable row (global/composite/index/sector) opens the existing OHLCV chart; commodities/currencies don't navigate.
- [x] **Paper Trading — regime-weighted 100M IDR portfolio** (§18): a persisted, mark-to-market paper account seeded with Rp 100,000,000 that allocates across the composite Watchlist, sizing total equity exposure by the market regime (§17) and each name by conviction, under explicit risk caps. **Propose-then-confirm**: the app generates a target rebalance (with per-line rationale), the user reviews and clicks Execute; holdings + realized/unrealized P&L track over time. A pure `AllocationEngine` does the sizing; a disk-backed `PaperTradingStore` records confirmed fills. No real orders.
- [x] **Build DMG**: `scripts/build_dmg.sh` produces a notarisable `Autoscreener.dmg`.

Out of scope for v1: real-time WebSocket price streaming (`wss-trading.stockbit.com`), saving custom templates, multi-account, paywall enforcement (we hit `paywall/eligibility/check` and surface the result, but don't gate UI), filter-builder UI (canned preset only). Charting and the Markets browser shipped after the original v1 cut (see §17).

---

## 2. Architecture

UDF-leaning MVVM (per `swiftui-architecture` skill default for SwiftUI 2026).

```
View (SwiftUI)
  ↑ binds to
ViewModel (@Observable, @MainActor)
  ↑ calls
UseCase / Service (LoginService, ScreenerService)
  ↑ uses
APIClient  (URLSession + AuthInterceptor)
  ↑ reads/writes
TokenStore (Keychain wrapper)
```

Modules / files:

```
Autoscreener/
├── App/
│   ├── AutoscreenerApp.swift              // @main, WindowGroup + Settings scene
│   └── AppDependencies.swift              // MainActor singleton: builds store/services/client + wires APIClient.setRefresher → LoginService.refresh
├── Core/
│   ├── Networking/
│   │   ├── APIClient.swift                // actor: pre-flight refresh (60s window) + 401 retry + concurrent-refresh collapse
│   │   ├── Endpoint.swift                 // URL, method, body, requiresAuth, header merge
│   │   ├── NetworkLog.swift               // @Observable in-memory ring buffer + LoggingHTTPSession decorator with key-based redaction
│   │   └── DTO/LoginDTO.swift             // LoginResponse decoder — trusted/new-device/flat envelopes, parses expired_at
│   ├── Auth/
│   │   ├── LoginService.swift             // login → LoginOutcome (.authenticated | .needsDeviceVerification) / refresh / storeTokens / signOut
│   │   ├── DeviceVerificationService.swift// startChallenge / sendOTP / verifyOTP → OTPVerifyOutcome / completeNewDevice
│   │   ├── TokenStore.swift               // KeychainTokenStore (actor); TokenPair carries accessExpiresAt + refreshExpiresAt
│   │   └── JWT.swift                      // payload-only exp decoder, used as fallback when server omits expired_at
│   └── Common/
│       └── DeviceInfo.swift               // x-devicetype / x-appversion / UA + persisted player_id UUID
├── Features/
│   ├── Settings/
│   │   ├── SettingsView.swift             // phase-driven Form + NetworkLogPanel
│   │   └── SettingsViewModel.swift        // Phase {.signIn | .verifying(VerificationState) | .signedIn}; auto-sends OTPs on default_channel
│   └── Screener/
│       ├── ScreenerView.swift             // controls + Table
│       ├── ScreenerViewModel.swift        // run(), loadMore(), sort
│       ├── ScreenerService.swift          // wraps POST /screener/templates
│       └── Models/ScreenerModels.swift    // ScreenerConfig, Filter, Universe, Row, Page
├── Autoscreener.entitlements              // app-sandbox + network.client (see §13)
└── Assets.xcassets
```

---

## 3. Auth flow

### 3.1 Login (sign-in step)
1. User enters username + password in **Settings**.
2. `LoginService.login(user:password:)` →
   ```
   POST https://exodus.stockbit.com/login/v6/username
   Content-Type: application/json
   Body: {"user":"…","password":"…","player_id":"<persisted-uuid>"}
   ```
   + standard headers (see §5).
3. The server returns HTTP 200 in **three** distinguishable shapes (decoder tries each in order):

   **a. Trusted device** — full token grant nested under `data.login`:
   ```
   {"data":{"login":{
     "user":{…},
     "token_data":{
       "access":  {"token":"<JWT>","expired_at":"2026-06-01T09:28:29Z"},
       "refresh": {"token":"<JWT>","expired_at":"2026-06-07T09:28:29Z"}},
     "support":{"id":"…"}}}}
   ```
   `LoginOutcome.authenticated(TokenPair)`. Persist + done.

   **b. New device** — MFA challenge (no tokens yet):
   ```
   {"data":{"new_device":{"multi_factor":{
     "login_token":"<l_token>","verification_token":"<v_token>"}}}}
   ```
   `LoginOutcome.needsDeviceVerification(loginToken, verificationToken)`. Go to §3.2.

   **c. Flat fallback** — `{"data":{"access_token":"…","refresh_token":"…"}}` or top-level flat fields. Kept for `/login/refresh` etc.
4. On HTTP 400/401: `LoginError.invalidCredentials`.

### 3.2 New-device MFA
Triggered by outcome 3.1.b. Three calls in order, all unauthenticated (the tokens in the body are the credentials):

```
POST /mfa/verification/v1/challenge/start         {"verification_token": "<v>"}
POST /mfa/verification/v1/challenge/otp/send      {"verification_token": "<v>", "channel": "CHANNEL_EMAIL" | "CHANNEL_WHATSAPP" | "CHANNEL_SMS"}
POST /mfa/verification/v1/challenge/otp/verify    {"verification_token": "<v>", "otp": "<6-digits>"}
```

Stockbit's flow is **sequential**, not a user choice — `verifyOTP` may return:
```
{"data":{"next_challenge":"CHALLENGE_OTP","supporting_data":{"otp":{
  "channels":[{"channel":"CHANNEL_WHATSAPP","target":"628******506"}, …],
  "default_channel":"CHANNEL_WHATSAPP"}}}}
```
meaning **another OTP is required** before we may proceed. We auto-`sendOTP` on the new `default_channel`, repeat until `next_challenge` is absent, then:

```
POST /login/v6/new-device/verify    {"multi_factor": {"login_token": "<l>"}}
```

returns a token grant in this shape (different from the trusted-device shape — note no `login` wrapper):
```
{"data":{
   "user":{…},
   "access":  {"token":"<JWT>","expired_at":"…"},
   "refresh": {"token":"<JWT>","expired_at":"…"}}}
```

UI: alternate-channel buttons remain available (e.g. "Switch to SMS" when WhatsApp's default) but the user never has to pick the *first* channel.

### 3.3 Pre-flight refresh
`TokenPair` carries `accessExpiresAt` / `refreshExpiresAt` (parsed from `expired_at`; falls back to JWT `exp`). On every authed `APIClient.perform`:

- if `refreshExpiresAt` is in the past → wipe Keychain, throw `.unauthorized` (UI bounces to sign-in)
- if `accessExpiresAt` is within **60 seconds** of now → call `/login/refresh` first, then send the original request with the new bearer

This prevents the guaranteed 401 round-trip on stale tokens. A single in-flight `Task<TokenPair, Error>` collapses concurrent refresh attempts.

### 3.4 401 backstop
If a request still returns 401 (server invalidated a token early, clock skew, …) we run a single refresh + retry, then fail hard. If refresh itself errors → wipe tokens, throw `.unauthorized`.

---

## 4. Screener call

The bootstrap for any screener on sign-in / refresh:

```
GET  /paywall/eligibility/check?company=&features=PAYWALL_FEATURE_SCREENER
POST /paywall/counter/increment            {"feature":"PAYWALL_FEATURE_SCREENER","company":""}
GET  /screener/templates/{templateID}?limit=25&type=TEMPLATE_TYPE_CUSTOM   ← page 1 lives here
POST /screener/templates                                                   ← pages 2, 3, …
```

**Key gotcha:** page 1 is bundled into the `GET /screener/templates/{id}` response. The POST endpoint is only for pages ≥ 2 — calling it with `page=1` returns no rows, which is what produced the original "No matches" bug.

### 4.0 Screener catalog

| Tab title | templateID | Filter | Sequence | Weight* |
|---|---|---|---|---|
| Bandar Accumulating | `6676213` | `Bandar Value > Bandar Value MA 20` **and** `Bandar Value > 0` | `[14399, 14426]` | 2.0 |
| Bandar Above MA20 | `6676217` | `Bandar Value > Bandar Value MA 20` | `[14399, 14426]` | 1.5 |
| Bandar Shift Today | `6676221` | `Bandar Value > Previous Bandar Value` | `[14399, 14425]` | 2.0 |
| Accum/Dist Positive | `6676223` | `Bandar Accum/Dist > 0` *(basic threshold)* | `[14400]` | 1.5 |
| 1M Net Foreign Flow | `6676225` | `1 Month Net Foreign Flow > 0` *(basic threshold)* | `[13580]` | 1.0 |
| 6M Net Foreign Flow | `6676228` | `6 Month Net Foreign Flow > 0` *(basic threshold)* | `[13582]` | 1.5 |
| 3M Net Foreign Flow | `6676231` | `3 Month Net Foreign Flow > 0` *(basic threshold)* | `[13581]` | 1.0 |
| Foreign Buy Streak ≥5 | `6676235` | `Net Foreign Buy Streak >= 5` *(basic threshold)* | `[13561]` | 1.0 |
| Fresh Foreign Buy | `6676238` | `Net Foreign Buy Streak > 0` *(basic threshold)* | `[13561]` | 1.5 |
| Frequency Spike | `6676260` | `Frequency Spike > 0` **and** `Frequency Analyzer >= 1.5` *(basic)* | `[15396, 15394]` | 1.0 |
| Volume Spike | `6676263` | `Volume >= 1.5 × Volume MA 20` *(compare, multiplier 1.5)* | `[12469, 12464]` | 1.0 |
| Above 50MA | `6676264` | `Price >= Price MA 50` *(compare)* | `[2661, 12460]` | 0.5 |
| Above 200MA | `6676268` | `Price >= Price MA 200` *(compare)* | `[2661, 12462]` | 1.0 |
| Liquidity Floor † | `6676314` | `Value MA 20 >= 5,000,000,000` *(basic threshold)* | `[16454]` | 0.5 |
| Intraday Liquidity † | `6676320` | `Value >= 10,000,000,000` *(basic threshold)* | `[13620]` | 0.5 |
| Watchlist | — | composite of all twenty above, deduped by symbol, veto-excluded | — | sum (max 22.5) |

† *Veto gate* — `bandar-master.json` declares these `veto: true`. Matching contributes `weight` to the composite score normally (weighted-OR), but a stock **missing from either** evaluable gate is **excluded from the Watchlist composite entirely** (hard-AND), regardless of bandar score. (The individual Liquidity Floor / Intraday Liquidity *screener tabs* still list their own rows — exclusion is a Watchlist-composite concern only.)

> **A gate only vetoes when it was actually evaluated.** Exclusion is applied by `WatchlistComposer.compose` over the cached snapshots, restricted to veto gates that have a snapshot in the `ScreenerStore` this generation. A veto gate whose fetch failed (no snapshot) is **not** enforced (and the status bar shows a "Liquidity veto not enforced" notice) rather than blanket-excluding every row. Without this, a single failed liquidity fetch would empty the whole watchlist.

‡ *Frequency Spike divergence* — `bandar-master.json`'s `freq-spike` rule is an **OR** (`bool(freq_spike) or freq_analyzer >= 1.5`), but the captured Stockbit template (6676260) ships two `basic` filters which the API **AND**-combines. We mirror the captured wire exactly so the per-tab page-2+ POSTs reproduce the GET's row set; the watchlist weight (1.0) is unchanged. The practical effect is a stricter Frequency Spike tab than the master spec's OR.

*Weights mirror `bandar-master.json` in the Ulysees repo. A symbol's Watchlist score is the sum of the weights of every screener it appears in. The two filter `type`s — `compare` (column vs column, item2 is a metric ID) and `basic` (column vs literal, item2 is a numeric string) — share the same wire shape; the Codable model `ScreenerFilter` round-trips both.

### 4.1 POST body (pages 2+)

```
Authorization: Bearer <access>
Content-Type: application/json

{
  "save": "0",
  "limit": 25,
  "page": <≥2>,
  "ordercol": 2,
  "ordertype": "desc",
  "sequence": "14399,14426",
  "filters": "<stringified JSON array>",
  "universe": "<stringified JSON object>",
  "type": "TEMPLATE_TYPE_CUSTOM",
  "name": "<name>",
  "description": "",
  "screenerid": "6676213"
}
```

- `filters` and `universe` are **double-encoded JSON strings** — match exactly.
- `sequence` = comma-separated metric IDs → drives which `results[]` entries the server returns.

### 4.2 Response shape (confirmed 2026-05-31)

```json
{
  "data": {
    "calcs": [
      {
        "company": { "symbol": "BOGA", "name": "Apollo Global Interactive Tbk.",
                     "country": "ID", "exchange": "IDX", "icon_url": "https://…" },
        "results": [
          { "id": 14399, "item": "Bandar Value",        "raw": "14925216921719.91", "display": "14,925.22 B" },
          { "id": 14426, "item": "Bandar Value MA 20", "raw": "14925216260264.54", "display": "14,925.22 B" }
        ]
      },
      …
    ],
    "total": <optional>
  }
}
```

Decoded via `ScreenerResponseDTO` (Codable, nested `DataDTO/CalcDTO/CompanyDTO/MetricResultDTO`). `CalcDTO.toRow(sequence:)` projects each row, parsing `results[].raw` as `Double` and aligning columns to `config.sequence` order. `ScreenerService.decodeResponse` tries Codable first, falls back to dict-walking for any unknown envelopes.

---

## 5. Common HTTP headers (sent on every request)

| Header | Value |
|---|---|
| `accept` | `*/*` |
| `accept-encoding` | `identity` |
| `accept-language` | `ID` |
| `content-type` | `application/json` (when body present) |
| `x-platform` | `iOS` *(server is iOS-aware; keep this even on macOS to avoid being rejected)* |
| `x-devicetype` | `iPhone 11` *(spoofed; revisit once we confirm the server tolerates `Mac`)* |
| `x-appversion` | `3.21.4` *(match a known-good client build)* |
| `user-agent` | `Stockbit/3.21.4 (stockbit.com.stockbit; build:40150; iOS 18.1.1) Alamofire/5.9.0` |

Construct once in `DeviceInfo.headers()` and merge into every `URLRequest`.

---

## 6. Settings UI

State machine in `SettingsViewModel`:
```swift
enum Phase: Equatable {
    case signIn                          // username + password TextField + Sign in
    case verifying(VerificationState)    // channel buttons + 6-digit code + Verify
    case signedIn                        // confirmation row + Sign out
}
```

`SettingsView` switches its `Form` body on `phase`. The macOS Settings scene is mounted under `AutoscreenerApp.body` and opened via `SettingsLink` from `ContentView` or `⌘,`.

### 6.1 `signIn` phase
- Username `TextField` + password `SecureField`, `.textContentType(.username)` / `.password` for autofill.
- Single "Sign in" button with `.keyboardShortcut(.defaultAction)`.
- Inline red text for `LoginError.invalidCredentials` / `.network` / `.malformedResponse`.

### 6.2 `verifying` phase
- Prompt copy adapts to `state.step` ("New device detected…" → "One more step. Stockbit needs to verify your phone too…").
- One row per `availableChannels` entry rendered as `Label("Resend Email" / "Switch to SMS", systemImage: …)`. Auto-`requestOTP` fires on entry using `state.defaultChannel`, so users only tap if they want to switch.
- "Code sent via Email to t***@e.com" banner (uses the server's masked `target`).
- 6-digit `TextField` (`.textContentType(.oneTimeCode)`, monospaced) + explicit "Verify" button (per user preference — no auto-submit).
- Errors map to inline red text. `DeviceVerificationError.challengeExpired` bounces back to `signIn` with a clear message.

### 6.3 Network log panel
Always-visible scrollable panel below the form. Each entry shows: timestamp, HTTP method, status badge (green 2xx / orange 3xx / red 4xx-5xx / red ERR), latency, URL, request body preview (`→`), response body preview (`←`).

Sensitive JSON keys are redacted to `***` **in the displayed copy only** — the wire request always carries the real values. Key list:
```
password, otp, login_token, verification_token, access_token, refresh_token, authorization
```

Backed by `NetworkLog.shared` (an `@Observable` ring buffer, last 50 entries) populated by `LoggingHTTPSession` — a decorator that wraps `URLSession.shared` in `AppDependencies` so login, MFA, and screener traffic all flow through it.

---

## 7. Results table

`SwiftUI.Table` with `sortOrder` binding. Columns (left to right):

| Column | Source | Sortable |
|---|---|---|
| `No` | computed `firstIndex` on the current rows array | no |
| `Symbol` | `company.symbol` (Stockbit-shape) or top-level `symbol` (legacy) | yes |
| `Name` | `company.name` | yes |
| *Metric 1* (e.g. `Bandar Value`) | `results[]` matched by id from `config.sequence[0]` | yes |
| *Metric 2* (e.g. `Bandar Value MA 20`) — only if `sequence.count > 1` | `results[]` matched by id from `config.sequence[1]` | yes |

The second metric column is conditional: single-column screeners like Accum/Dist Positive (`sequence: [14400]`) render only one metric column.

**Column widths:** `No` and `Symbol` are pinned to fixed widths (`.width(44)` and `.width(60)`) rather than flexible min/ideal ranges — the row index never exceeds the ~900-stock IHSG universe (4 digits) and IDX tickers are 4–5 letters, so neither needs to grow. This keeps both columns tight and hands the freed horizontal space to `Name` and the metric columns. The same widths apply in the Watchlist table (§15), which shares the column layout but swaps the two metric columns for `Score` + a `Screeners` icon column (§7.4).

The `Last` / `Δ%` columns from the original sketch were removed — Stockbit's `screener/templates` response doesn't carry intraday price for metric-only filters (those come from `/company-price-feed`, separate feature).

### 7.1 No view-side pagination (superseded by the sweep cache)

Screener tabs no longer paginate at the view layer. The sweep coordinator already walks every page per screener (page 1 via `GET`, pages 2+ via `POST`, terminating on empty / partial-page / total / a 20-page safety cap) and stores the **full result set** as one `ScreenerSnapshot`. A tab renders all rows from that snapshot at once; there is no `loadMore`/`rowDidAppear`. Pagination end-of-list detection now lives in `DataSweepCoordinator.fetchAll` (see §15).

### 7.4 Watchlist screener-icon column (`Features/Watchlist/ScreenerIconStrip.swift`)

The 20 individual screener screens were dropped from the sidebar — they were one-off tables the user rarely opened, while the composite Watchlist is the real radar. The screener **sweep and data are untouched** (`DataSweepCoordinator` still fills `ScreenerStore`; `start()` is idempotent and is triggered by the Watchlist / Markets / Paper-Trading screens regardless). Their `SidebarItem` cases, `ScreenerViewModel`s, and `ScreenerView` routes remain in code (unreachable but compiling) for easy reversibility.

In their place, each Watchlist row carries a `Screeners` cell immediately **right of the `Score`** (originally a `Table` column; since the Watchlist was merged into the Recommendations screen it's a `WatchlistRowView` in a `LazyVStack` — see §14). For each row it renders `ScreenerIconStrip(kinds: row.matchedScreeners)` — a horizontal strip of small SF Symbols, one per screener the stock matched, each with a `.help(displayName)` hover tooltip and an `accessibilityIdentifier("watchlist.screeners-<TICKER>")` on the cell.

- **Signal screeners only.** `ScreenerIconCatalog.displayed(from:)` filters to non-veto kinds (`!isVeto`) in canonical `allCases` order — the two liquidity gates are excluded because every surviving row passed both, so their icons would be constant noise.
- **Tinted by family.** `ScreenerFamily` groups the kinds into bandar accumulation (purple), foreign flow (teal), price/volume activity (orange), fundamentals (green), and liquidity (secondary). The per-kind SF Symbol and family map live in the view layer (`ScreenerIconCatalog`), keeping the `Codable`/`Sendable` `BandarScreenerKind` domain enum SwiftUI-free. These pure `static` helpers are unit-tested (`ScreenerIconCatalogTests`).

### 7.2 Toolbar + status bar

- Header row: `config.name` (template name) and `config.universe.scope`, plus a `ProgressView` while a sweep is in flight (`coordinator.isSweeping`), and a Refresh button (forces an immediate sweep). An "as of HH:mm" badge shows when the cached snapshot landed.
- Status bar (below the table): "N rows". With an active search it switches to "N of M rows match".

### 7.3 Stock-code search

The **Liquidity Floor** and **Intraday Liquidity** tabs — and the **Watchlist** (§15) — expose a `.searchable` toolbar field. It's opt-in per tab via `ScreenerView(enableSearch:)` (the Watchlist always has it), so the other 18 screener tabs that share `ScreenerView`/`ScreenerViewModel` are unaffected. Matching is a case-insensitive substring over the row's `symbol` **only** (company name is not matched); a blank/whitespace query shows everything. The view renders `vm.visibleRows` (the filtered set) instead of `vm.rows`, and a no-match search shows `ContentUnavailableView.search`.

The filter is a single shared implementation: `Array.filteredBySymbol(_:)` on the `SymbolSearchable` protocol, to which both `ScreenerRow` and `WatchlistRow` conform — so the two screener tabs and the Watchlist share one tested code path (`SymbolSearch.swift`).

Since every snapshot holds the screener's full result set (the sweep walks all pages), the filter is always complete — there's no page-exhaust step. The Watchlist likewise holds the full aggregated set. Search terms are transient UI state, never persisted.

---

## 8. Persistence

| What | Where |
|---|---|
| Access + refresh tokens | Keychain (`kSecClassGenericPassword`, account `stockbit-tokens`, accessible `WhenUnlockedThisDeviceOnly`) |
| `player_id` UUID | `UserDefaults` (`autoscreener.playerID`) — stable per install |
| Last-used screener config (filters, universe, sequence, name) | `UserDefaults` JSON blob (`autoscreener.lastScreener`) |
| Password | **Never** — held in `@State` for the duration of the Settings form, cleared on submit |

---

## 9. Errors & states

| Error | Surface |
|---|---|
| `LoginError.invalidCredentials` (400/401 on `/login/v6/username`) | "Invalid username or password." inline under sign-in form |
| `LoginError.network` | "Couldn't reach Stockbit. \(detail)" |
| `LoginError.malformedResponse` | "Unexpected server response. Please try again." |
| `DeviceVerificationError.invalidOTP` | "Invalid or expired code. Please try again." — stays on the OTP screen, lets user re-type |
| `DeviceVerificationError.challengeExpired` (server says token expired) | Bounce to `.signIn` with "Verification challenge expired. Please sign in again." |
| `DeviceVerificationError.otpDeliveryFailed` (5xx on `otp/send`) | "Couldn't deliver the code right now. Try the other channel." |
| `APIError.unauthorized` after a failed pre-flight or refresh attempt | Wipe Keychain; `ContentView` swings back to sign-in prompt |
| `ScreenerError.paywall` (402/403 on `screener/templates`) | Banner above table |

---

## 10. Testing

191 unit tests at present (`xcodebuild -only-testing:AutoscreenerTests test`). Coverage:

- `JWTTests` — payload base64url decode, `isExpiring` window
- `LoginServiceTests` — request body + headers, three response envelopes (trusted-device, new-device, flat), `expired_at` parsing, MFA outcome detection, 401 → `invalidCredentials`, refresh bearer attach
- `DeviceVerificationServiceTests` — request shapes for all four MFA endpoints, channel/target parsing from `supporting_data.otp`, `next_challenge` detection, error mapping (invalid OTP, challenge expired)
- `APIClientAuthInterceptorTests` — bearer attach, 401-then-refresh-then-retry, refresh-failure wipes tokens, **pre-flight refresh fires within the 60s window**, dead refresh wipes Keychain
- `SettingsViewModelTests` — happy sign-in, invalid creds surface, sign-out toggle, **multi-step MFA flow chains email → phone → completes**, invalid OTP stays in verification phase, expired challenge bounces back
- `ScreenerServiceWireFormatTests` — exact double-encoded `filters`/`universe` strings vs the captured fixture; pagination
- `ScreenerServiceParseTests` — three response envelope shapes + values-array / id-keyed metric layouts + missing-values tolerance
- `ScreenerViewModelTests` — run, loadMore, clear-on-rerun, error mapping
- `NetworkLogRedactionTests` — every sensitive key gets `***`, case-insensitive
- `SymbolSearchTests` — shared `filteredBySymbol`: blank/whitespace passthrough, case-insensitivity, substring match, no-match-empty, symbol-not-company-name, surrounding-whitespace trim
- `ScreenerSearchTests` — `visibleRows` tracks `searchText`; `loadAllForSearch()` exhausts every remaining page and leaves `hasMore == false`
- `WatchlistSearchTests` — `visibleRows` filters by symbol (blank passthrough, case-insensitive, symbol-not-name)
- `ScreenerIconCatalogTests` (§7.4) — the Watchlist screener-icon column logic: `displayed(from:)` drops both veto gates and keeps `allCases` order, a veto-only row → empty strip, every `BandarScreenerKind` has a non-empty SF Symbol, family mapping for representative kinds
- `CommodityPriceServiceTests` — `emitten/{symbol}/info` endpoint shape; parse of live OIL/XAU/CPO captures (string vs JSON-number fields, signed `change`, comma-grouped `formatted_price`, integer-string price, `"NA"` value/average tolerance); non-numeric-price + malformed-JSON throws; error mapping through a real `APIClient` + `StubSession` (unauthorized / paywall 403 / malformed / happy path)
- `MarketQuotesViewModelTests` / `RegimeViewModelTests` — thin store projections: `quotes`/`read` mirror the `MarketDataStore`; empty store → empty/nil; no spinner once data has landed
- `MarketDataStoreTests` — `applyQuotes` merge-keeps-prior + version bump, empty-apply no-op, `apply(regimeRead:)`, quotes + regime read round-trip to `market-cache.json`, corrupt file loads empty
- `LQ45BreadthTests` — LQ45 ∩ `.above200MA` snapshot over the fixed-45 denominator; nil without a snapshot / without constituents; zero-above case
- `RegimeComposerTests` — composes a read from available inputs (valuation/breadth/foreign-flow factors present, trend absent without a series); nil when no factor is produced; degrades without the snapshot; breadth factor absent without a screener snapshot
- `DataSweepCoordinatorTests` — **screener path** (paywall-once, 20 in order, pagination/safety-cap, throttle count, mid-sweep cancel, partial-failure error, fixture seed/veto, open-sweeps/closed-skips loop, closed cadence gap); **market path** (`openSweepPricesEveryCatalogSymbol`, `closedSweepPricesAroundTheClockGroupsOnly`, failed-symbol keeps prior, serial throttle); **regime path** (open composes + writes the read incl. derived breadth, closed leaves the read frozen)
- `MarketCatalogTests` — declaration order (`.global` first, then `.composite`…`.currency`), all 11 global indices present + chartable, all 18 commodity/currency symbols present, all 11 IDX-IC sectors, all 5 currency pairs (USD/IDR, SGD/IDR, EUR/IDR, AUD/IDR, CNY/IDR)
- `AllocationEngineTests` (§18) — the regime-gated allocator: risk-off parks ≥70% in cash; risk-on deploys >60% but ≤95% (survive-first cash floor); nil regime → neutral band; no name exceeds the per-name cap; full deployment honours the position-count floor; fractional-Kelly damps the top name vs raw-proportional; lot rounding to 100; empty/no-price/dropped-name handling; sub-band deltas suppressed. **Gate-5 exit overlay:** `.exit` fully sells a still-high-conviction held name + bars re-entry + overrides the anti-churn band; `.trim` caps at current (no add) but still rebalances down; `.hold`/empty matches the regime-only baseline
- `PaperTradingStoreTests` (§18) — fresh store seeded with 100M; buys spend cash + open positions; empty plan is a no-op; sell books realized P&L matching `Portfolio.apply`; reset returns to seed; portfolio round-trips to `paper-trading-cache.json`; corrupt file keeps the seed
- `PaperTradingViewModelTests` (§18) — the screen's wiring (headless stand-in for the XCUITest): joins the three stores, `canPlan` once watchlist + prices load, `generatePlan()` proposes buys, `execute()` books them into Holdings + spends cash, `reset()` returns to seed; **Gate-5**: `generatePlan()` bars re-entry / sells a held name flagged in `ExitDecisionsStore`. `PositionReviewViewModelTests` covers the writer side (a review feeds the store)

**UI verification.** Confirm UI changes with XCUITest under `-UITestFixtures`, never via the Accessibility API or screenshot scripts (flaky on multi-display macOS). `AutoscreenerUITests`:
- `StockDetailUITests` — tap a stock code → financial-detail flow (report/period switching)
- `MarketsUITests` — sidebar → Markets → Commodities/Currencies sections render with stubbed price + % change; Global section header + an SP500 priced row render; composite/index/sector rows also render as priced rows (`MarketsPricedRow.<symbol>`); chartable rows still navigate while commodities/currencies don't
- `RegimeUITests` — sidebar → Markets → regime banner shows the (deterministic Neutral) stance → tap → full factor breakdown (valuation / BI rate / LQ45 breadth rows)
- `PaperTradingUITests` (§18) — sidebar → Paper Trading → render → wait for the enabled Generate button → generate a plan → assert a `PaperTradingPlanRow_BBCA` buy → Execute → `PaperTradingHoldingRow_BBCA` lands in Holdings

All guard `XCTSkipIf(NSScreen.screens.count > 1)` — they pass on single-display/CI and skip on multi-display dev machines, where XCUITest can't snapshot a window on another Space. Full sign-in remains a real-network smoke (run manually).

---

## 11. Build & distribution

- Scheme: `Autoscreener` (Release config) → `.app` in DerivedData.
- `scripts/build_dmg.sh` (see repo) — archives, exports a Developer ID–signed `.app`, wraps it into `Autoscreener.dmg` with a drag-to-Applications layout. Notarisation step is a separate manual `xcrun notarytool submit` once Apple Developer creds are in env.

---

## 12. Open questions

1. **Server tolerance for non-iOS headers**: spec currently spoofs iOS. If we want a real Mac UA we need to test.
2. **Metric catalog**: `/screener/preset` likely returns the full metric ID → label map. Need to call it once and ship as bundled JSON or refresh on launch.
3. **Paywall**: is `screener/templates` blocked server-side for non-eligible users, or only metered? Decides whether we need to honour `eligibility/check`.
4. **`/screener/templates` response envelope** — current decoder tolerates three plausible shapes; lock on first live call.

---

## 13. Sandbox entitlements

`Autoscreener/Autoscreener.entitlements` (wired via `CODE_SIGN_ENTITLEMENTS` in every build config):

| Key | Value | Why |
|---|---|---|
| `com.apple.security.app-sandbox` | `true` | matches `ENABLE_APP_SANDBOX = YES` |
| `com.apple.security.network.client` | `true` | required for any outgoing URLSession traffic — without it `URLSession` returns `NSURLErrorCannotFindHost` ("server with specified name could not be found") in a sandboxed app |

If you ever need to talk to a non-HTTPS host, add a per-host `NSAppTransportSecurity` exception in `Info.plist`. We don't — all Stockbit endpoints are HTTPS.

## 14. Status

v1 + fifteen screeners (four bandar + three foreign-flow horizons + foreign-buy-streak + fresh-foreign-buy + two tape-activity spikes + two trend MA rules + two veto-gate liquidity rules) + composite Watchlist all shipped and exercised end-to-end against the real backend:
- Sign-in works for trusted devices (token grant) and new devices (MFA flow with sequential email→phone OTPs auto-fired on `default_channel`).
- Tokens persist with their `expired_at`; `APIClient` auto-refreshes inside the 60-second window and surrenders cleanly when the refresh JWT is dead.
- `AuthState` (`@Observable`) drives ContentView's main → signin transition without a synchronous Keychain probe, eliminating the unit-test Keychain trust prompt.
- Settings has the redacted network log (⌘,); the main screener window keeps a minimal toolbar — just title + spinner.
- Sidebar lists fifteen screener tabs (Bandar Accumulating, Bandar Above MA20, Bandar Shift Today, Accum/Dist Positive, 1M Net Foreign Flow, 6M Net Foreign Flow, 3M Net Foreign Flow, Foreign Buy Streak ≥5, Fresh Foreign Buy, Frequency Spike, Volume Spike, Above 50MA, Above 200MA, Liquidity Floor, Intraday Liquidity) plus the composite Watchlist. Each tab holds its own `ScreenerViewModel`, so switching back-and-forth doesn't re-fire the paywall counter.
- Each tab runs on first reveal: paywall check + increment → `GET /screener/templates/{id}` (page 1) → infinite-scroll POSTs for pages 2+, terminating on empty / partial-page / total-reached. The 2nd metric column is conditional on `sequence.count > 1` (Accum/Dist Positive, the three foreign-flow screeners, Foreign Buy Streak ≥5, Fresh Foreign Buy, and both veto-gate liquidity tabs are single-column; Frequency Spike, Volume Spike, Above 50MA, and Above 200MA each carry two columns).
- Watchlist fans out to all fifteen templates **sequentially** with a randomised 1000–1500 ms throttle gap between requests (Stockbit penalises parallel bursts), unions rows by symbol, scores by per-rule weight (`bandar-master.json`, max composite **17.5**), sorts descending. Veto-gate rules (Liquidity Floor, Intraday Liquidity) flip a per-row `isVetoed` flag when the stock is missing from either gate — the table renders Symbol/Name in red and shows an "ILLIQUID" Flag column (tooltip lists which gate(s) failed). One paywall counter increment for the whole composite. Cancellation mid-bootstrap (tab switch while a fetch is in flight) is treated as internal noise and re-tried on next view appearance — never surfaced as an error banner.
- Real Stockbit envelope (`data.calcs[].company.{symbol,name}` + `data.calcs[].results[].{id,raw}`) decoded via Codable; rows sorted by template default on each load.

**API-fetching revamp (2026-06-11).** Replaced the on-demand, uncached fetch model with a single continuous market-hours sweep into a disk-backed cache (see §15). New types: `MarketClock` (IDX sessions), `ScreenerStore` (disk-persisted snapshot cache), `ScreenerSweepCoordinator` (owns the loop + fan-out, moved out of `WatchlistViewModel`), `WatchlistComposer` (union + veto exclusion). `ScreenerViewModel`/`WatchlistViewModel` are now thin store projections (no fetching/pagination). **Veto changed from tag → exclude**: stocks missing a liquidity gate are dropped from the composite (the ILLIQUID column and `WatchlistRow.failedVetoGates`/`isVetoed` were removed). Today's Picks is hidden from the sidebar (feature code retained); the app lands on the Watchlist. Full unit suite green (added `MarketClockTests`, `ScreenerStoreTests`, `ScreenerSweepCoordinatorTests`, `WatchlistComposerTests`; rewrote the screener/watchlist VM + search suites for the store model) plus a `WatchlistUITests` cache/exclusion check. Next milestone in §16.

**Markets + Regime UI merge (2026-06-11).** Collapsed the two "Markets"-section sidebar entries ("Market Regime" + "Markets") into a single **Markets** screen: the regime read now sits as a banner atop the instrument list, tappable to push the full factor breakdown (`RegimeBreakdownView`, extracted from the deleted `RegimeView`; `RegimeColors` moved alongside it). `RegimeViewModel` + `CommoditiesViewModel` (later renamed `MarketQuotesViewModel`) hoisted into `MainSidebarView` to preserve loaded data across tab switches and avoid re-firing the breadth fan-out on every visit; the two load concurrently. `RegimeUITests` rewritten for the Markets → banner → breakdown flow. Build + full unit suite green; UI tests skip on multi-display dev machines (run on single-display/CI). See §17.

**Markets — price + % change on IHSG, indices & sectors (2026-06-11).** The composite/index/sector rows now show a live last-price + signed % change like commodities/currencies, instead of plain `symbol + name`. Stockbit's `emitten/{symbol}/info` returns the same price-header shape for indices/stocks as for commodities, so the existing `CommodityPriceService` path is reused with zero new wiring. `CommoditiesViewModel` → **`MarketQuotesViewModel`** (now fans out over `MarketCatalog.all`, ~35 concurrent requests, per-symbol failure still tolerated); `MarketCatalog.priced` dropped (every group is quoted); `MarketsView` routes all groups through the priced row while keeping the `.hasChart` NavigationLink wrapping (composite/index/sector stay tappable into the chart). Tests: `MarketQuotesViewModelTests` gains a default-catalog-covers-chartable-groups case; `MarketsUITests` gains a priced-row check for IHSG/index/sector. Build + full unit suite green; UI tests skip on multi-display (run on single-display/CI). See §17.

**Markets — non-USD currency pairs (2026-06-11).** Added four FX pairs alongside USD/IDR under **Currencies**: SGD/IDR, EUR/IDR, AUD/IDR, CNY/IDR. All four confirmed live on the same `emitten/{symbol}/info` snapshot path USD/IDR already uses (HTTP 200 with a populated price header). Pure data change — four `MarketSymbol` rows in `MarketCatalog`; `MarketQuotesViewModel` already fans out over `MarketCatalog.all` and the regime layer still reads only the hardcoded `USDIDR`, so no service/VM edits. Tests: `MarketCatalogTests` FX expectation set extended and `usdIdrIsTheOnlyCurrency` → `coversAllCurrencyPairs`. Catalog suite green. See §17.

**Markets — Global indices section (2026-06-11).** Added a **Global** section of 11 world indices (S&P 500, Dow Jones, Nasdaq, FTSE 100, DAX, CAC 40, Nikkei 225, Hang Seng, KOSPI, Shanghai, Straits Times) directly below the regime banner — surfacing the global context the regime's global-equities leg already reads. Pure data change: a `MarketGroup.global` case (declared first → renders below the banner) plus the symbols in `MarketCatalog`; pricing (`MarketQuotesViewModel` fan-out over `MarketCatalog.all`) and chart navigation (`.hasChart`) are already generic, so no service/view-model edits. Stockbit serves world indices on the same `emitten/{symbol}/info` + `charts/{symbol}/daily` paths as IDX symbols. Tests: `MarketCatalogTests` order assertion updated + `coversAllGlobalIndices`/`globalIndicesAreChartable` added; `MarketsUITests` gains a Global-header + SP500 priced-row check. Symbols from a request capture, pending live confirmation (§17.4). Build + full unit suite green; UI tests skip on multi-display (run on single-display/CI). See §17.

**Markets + Regime folded into the unified sweep (2026-06-11).** The Markets price list and the regime read now flow through the **same throttled, disk-backed, market-clock-driven fetch path as the screeners** — previously they fired ~100 un-throttled concurrent requests on every screen appearance. `ScreenerSweepCoordinator` → **`DataSweepCoordinator`**: one `runSweep(includeIDX:)` prices `MarketCatalog.all` and synthesises the regime read through the **same anti-burst throttle** as the screeners, writing a new disk-backed **`MarketDataStore`** (`market-cache.json`: quotes + `RegimeRead`). `MarketQuotesViewModel`/`RegimeViewModel` became thin store projections (no fetching). **Cadence** keys off `MarketGroup.isIDXSession`: open → full sweep every 5–10 min; closed → only global/commodity/FX legs refresh every 20–30 min while IDX-session legs (screeners, composite/index/sector quotes, regime) freeze. **Breadth is now derived** from the `.above200MA` screener snapshot via `LQ45Breadth` (zero extra chart calls; the old 45-per-constituent fan-out is gone); `RegimeComposer` is the pure synthesis the coordinator calls. `BreadthService` kept (the §8 selection engine still uses it). `CommodityQuote`/`RegimeRead` made `Codable` for persistence. Tests: new `MarketDataStoreTests`, `LQ45BreadthTests`, `RegimeComposerTests`, `DataSweepCoordinator{Market,Regime}Tests`; VM suites rewritten as projections; all pre-existing screener tests unchanged. Build + full unit suite green; UI tests require automation-mode permission (run on a configured single-display machine/CI). See §15, §17.

**Markets — section reflow (2026-06-12).** Re-grouped the dashboard sections into three balanced two-column rows so related instruments sit side by side and the right column no longer towers: **row 1** = regime banner + **Global**; **row 2** = composite (IHSG) over indices on the left, **Sectors** (2-col grid) beside them on the right; **row 3** = Commodities + Currencies (unchanged). Pure layout change in `MarketsView` (`body` reflow + the regime `.ready` frame now fills its HStack cell instead of the whole row); no new types, no service/VM edits, accessibility identifiers unchanged so `MarketsUITests` still match by identifier regardless of position. Build + `MarketsUITests` green (UI tests skip on multi-display dev machines; run on single-display/CI). See §17.

**Markets — Sectors to its own full-width single-column row (2026-06-12).** Sectors left the shared row-2 grid for its **own full-width row** rendered as a **single column** (dropped the `columns: 2` arg; `MarketSectionCard` defaults to `columns: 1`). Row 2's freed right slot now stacks **Commodities over Currencies** mirroring the composite/indices stack on the left, so the dashboard reads: **row 1** = regime + Global; **row 2** = composite/indices ∥ commodities/currencies; **row 3** = Sectors (full width, 1 col). Pure `MarketsView` `body` reflow; no new types, no service/VM edits, accessibility identifiers unchanged. Build + `MarketsUITests` green (skip on multi-display, run on single-display/CI). See §17.

**Paper Trading — regime-weighted 100M IDR portfolio (2026-06-12).** A new **Paper Trading** sidebar screen joins the two halves the app already produced but never connected: the conviction-scored composite Watchlist (§4.0/§15.4) and the market-regime read (§17). A persisted, mark-to-market 100M IDR account allocates across the watchlist via a three-layer framework — **(1)** regime score → target equity exposure (Zweig "don't fight the Fed/tape": risk-off 0–30%, neutral 50–60%, risk-on ≤95% with a survive-first cash floor); **(2)** rank priced watchlist names by `WatchlistRow.score`, top-N; **(3)** conviction → fractional-Kelly-damped, per-name-capped, position-count-floored, lot-rounded weights (Against the Gods: size for survival, diversify, don't chase the extreme). **Propose-then-confirm** — `AllocationEngine.plan(...)` (pure) proposes a rebalance with per-line rationale; the user clicks Execute; `PaperTradingStore.apply(...)` books sells-then-buys through `ExecutionModel.standardIDX` (lot 100, 0.15%/0.25% fees, slippage) and persists to `paper-trading-cache.json`. Reuses, not rebuilds: `RegimeRead`, `WatchlistComposer`, `ScreenerRow.lastPrice` for the price map, and the `Portfolio`/`Lot`/`TradeSide`/`ExecutionModel` value primitives from `BacktestHarness.swift` (`TradeSide` gained `String`+`Codable` for persistence). New folder `Features/PaperTrading/` (models, engine, `@Observable` store, projecting VM, view); wired into `MainSidebarView` + `AppDependencies` (headless-seeded under fixtures). Tests: `AllocationEngineTests`, `PaperTradingStoreTests`, `PaperTradingViewModelTests`, `PaperTradingUITests`. Full unit suite green; UI test skips on multi-display (the VM test covers the generate→execute→holdings flow headlessly). See §18.

**Selection engine — Gate-5 exit/sell discipline, Phase 1 (2026-06-13).** The Tier-A `StockSelectionEngine` (the headless "Today's Picks" reasoner; full plan in `INTEGRATION.md`) was **buy-only** — `run()` maps universe → ranked recommendations and never says when to *sell*. Gate-5 adds the mirror image — a held book → hold/trim/exit decisions — as a **sibling use case** (`Features/Selection/ExitEvaluator.swift`), deliberately *not* a stage inside `run()` (different input/output/reason-to-change), so the locked pipeline golden master stays byte-for-byte. The sell taxonomy reverses the buy-side investing frameworks the engine already encodes (Fisher *When to Sell* + Graham *Mr. Market* + Howard Marks defense): **Tier-1a** a buy-side hard gate now FAILS on current data (Forensic/Solvency/CapitalStrength/DataIntegrity) ⇒ exit (deterioration); **Tier-1b** the Gate-2 `governanceVeto` fires on current `.concern` insider/dilution flags ⇒ exit (integrity); **Tier-2** current margin-of-safety ≤ `exit.exitMarginFloor` ⇒ exit (Graham valuation); **Tier-3** regime target exposure ≤ 0 ⇒ trim (normal risk-off sizing stays the Paper Trading `AllocationEngine`'s job); else **hold**. The Fisher↔Graham reconciliation is a **hysteresis band**: you buy at `policy.minMarginOfSafety` (positive) but only sell at `exitMarginFloor` (**−0.30**, "let winners run"), and because the valuator recomputes intrinsic value from *current* fundamentals every review, a compounding winner is never sold on a risen price alone. Reuses each held name's own `SelectionProfile` (archetype seam — a held bank uses CapitalStrength + the justified-P/B valuator), the existing `governanceVeto`, and the valuator's `marginOfSafety`; pure + clock-free like the buy engine. New `SelectionConfig.ExitParams` (trailing-defaulted ⇒ every preset source-compatible); new gateway `HoldingsProvider` (DIP — Paper Trading store / a real brokerage conform later); sibling driver `PositionReviewer.review()` (reads the regime once, like `run()`). Tests: `ExitEvaluatorTests` (16 cases — one trigger each, incl. Fisher's explicit NON-triggers asserted as HOLD: a −68% paper drawdown with intact gates, and a price *above* intrinsic value but inside the band). **Full unit suite: 679 passed, 0 failures; golden master byte-for-byte unchanged.** Deferred: Phase 2 (persist an entry-thesis snapshot → true "thesis-was-wrong"/"IV-collapsed-since-entry" + Lynch category bands) and Phase 3 (`PaperTradingStore: HoldingsProvider` + feed exit decisions into the paper-trading plan + a "Positions to review" surface). See `INTEGRATION.md` for the detailed plan.

**Selection engine — Gate-5 Phases 2–4 (2026-06-13 → 2026-06-14).** **Phase 2** added a persisted `EntryThesis` snapshot so the evaluator sees what current data can't — a Tier-1c *thesis break* (re-computed intrinsic value collapsed ≥35% vs the entry IV; price-independent) + Lynch category-aware exit bands. **Phase 3** surfaced it: `PaperPosition.thesis` recorded cheaply on a buy-open (reusing the engine's IV/MoS via `RecommendationsStore`, no per-fill re-run), `PaperTradingStore: HoldingsProvider`, a new **Positions to Review** sidebar screen (`PositionReviewViewModel`/`PositionsReviewView`), and Gate-2/3 audit badges on Today's Picks — all golden-master-neutral. **Phase 4 (2026-06-14) closed the loop:** Gate-5 verdicts now *drive* the Paper Trading allocator (was surface-only). `AllocationEngine.plan` gained `exitDecisions: [String: ExitAction] = [:]` (§18.2) — `.exit` bars a name from the buy candidates **and** forces a held lot to a full sale (overriding the anti-churn band); `.trim` caps the target at the current size (no add, downward rebalance preserved); `.hold`/empty = byte-for-byte the regime-only plan. The verdicts ride a new `ExitDecisionsStore` (`@MainActor @Observable`, ticker→`ExitAction`, mirror of `RecommendationsStore`), written by `PositionReviewViewModel.load()` and read by `PaperTradingViewModel.generatePlan()`, so the allocator acts on the discipline without re-running the expensive holdings review per rebalance. Purely additive — the new input is trailing-defaulted, so `BacktestHarness` and the `SelectionEngineCharacterizationTests` golden master are unchanged. Tests (TDD): +6 `AllocationEngineTests`, +2 `PaperTradingViewModelTests`, +1 `PositionReviewViewModelTests`; **full `AutoscreenerTests` bundle: TEST SUCCEEDED, golden master byte-for-byte.** Still open (cosmetic): no screen badges an allocator line as a Gate-5 forced exit vs a regime trim.

**UI — unified Recommendations screen (2026-06-14).** Merged the two confusing buy/sell verdict surfaces into ONE ranked inbox to answer "what do I do today?". `TodaysPicksView` + `PositionsReviewView` were deleted and replaced by `RecommendationsView` + `ActionRowView` (+ `RecommendationFormatting`, where the Gate-2/3 badge parser moved from `TodaysPicksView`) over a thin `RecommendationsViewModel` that *owns* the two kept child VMs (`TodaysPicksViewModel`/`PositionReviewViewModel`) — they still load from their sources and still feed `RecommendationsStore`/`ExitDecisionsStore`, so the paper-trading allocator's caches and the **golden master stay byte-for-byte** (no engine/store/allocator change). `ActionRow` = `.buy(Recommendation)` | `.verdict(ExitDecision)`; the pure `merge` sorts EXIT→TRIM→BUY→HOLD then ticker and dedupes by ticker (**a held name's verdict wins over a fresh buy**). Sidebar collapsed `.todaysPicks` + `.positionsReview` → one `.recommendations` item, now the **default landing** (was `.watchlist`); Watchlist stays the radar. The landing change rippled into `WatchlistUITests`/`StockDetailUITests`/`GlobalFetchStatusUITests` (they now click Watchlist first), and a buy-only `BBCA` fixture was added so the merged list shows a pure BUY row alongside the verdicts. Tests (TDD): new `RecommendationsViewModelTests` (7 — merge order, verdict-wins dedupe, state aggregation) + `RecommendationFormattingTests` (badge parser re-homed); **full `AutoscreenerTests` bundle: TEST SUCCEEDED, golden master byte-for-byte**; new `RecommendationsUITests` is the CI proof (the UI runner is env-blocked on this dev box — the standing caveat; an unmodified suite fails identically). Open (cosmetic): a held name that's also a strong buy shows only its verdict (no "ADD" hint yet).

**UI — screeners off the sidebar → per-stock screener-icon column on the Watchlist (2026-06-14).** Removed the 20-row "Screeners" `Section` from `MainSidebarView` — they were one-off tables the user rarely opened; the composite Watchlist is the real radar. **Sweep + data untouched**: `DataSweepCoordinator.start()` is idempotent and already triggered by the Watchlist/Markets/Paper-Trading screens, and the default landing was already `.recommendations`, so nothing about the fetch changed. The `SidebarItem` screener cases, `ScreenerViewModel`s, and `ScreenerView` routes stay in code (unreachable but compiling) for reversibility. In their place the Watchlist `Table` gains a `Screeners` column right of `Score`: new `ScreenerIconStrip` renders `row.matchedScreeners` (which `WatchlistComposer` already populates) as a strip of tinted SF Symbols — **signal screeners only** (`!isVeto`, in `allCases` order; the two liquidity gates are omitted as they hold on every surviving row), **tinted by family** (bandar=purple, foreign=teal, activity=orange, fundamental=green), each with a `.help(displayName)` tooltip and a `watchlist.screeners-<TICKER>` cell id. All presentation (SF Symbol + family/tint) lives in the view-layer `ScreenerIconCatalog`, keeping the `Codable` `BandarScreenerKind` SwiftUI-free (§7.4). Tests (TDD): new `ScreenerIconCatalogTests` (4 — veto-drop + canonical order, veto-only→empty, non-empty symbol totality, family mapping); `WatchlistUITests` extended to assert the `watchlist.screeners-BBCA`/`-TLKM` strips render. **Full `AutoscreenerTests`: TEST SUCCEEDED, golden master byte-for-byte** (no domain change); `WatchlistUITests` **passed live** on this single-display box. Open (optional): prune the now-dead screener VMs/routes/cases; make icons tappable into the (still-coded) screener screen.

**UI — in-app "Settings" sidebar tab removed (2026-06-14).** Dropped the bottom-of-sidebar **Settings** tab (`AppSettingsView` — *Signed in / Log out / About / data-refresh note*) from `MainSidebarView`: its `SidebarItem.appSettings` case (+ `title`/`systemImage`/`templateID` arms), the sidebar `Section` that rendered it, and the `detail` switch arm were removed, and `AppSettingsView.swift` was deleted (the target is a `PBXFileSystemSynchronizedRootGroup`, so no `.pbxproj` edit). **Auth is untouched** — the macOS **Settings *scene*** (⌘,, `SettingsView`/`SettingsViewModel`, §6) is a separate window and still owns the only sign-in/sign-out path; the signed-out prompt still routes there via `SettingsLink`. Note: that tab held the only *in-app* Log out button, so log out now lives only under ⌘,. Nothing iterates `SidebarItem.allCases`, so removing the case is inert elsewhere. Tests: new `SidebarUITests.testSidebarHasNoSettingsTab` (under `-UITestFixtures`, asserts Recommendations/Markets/Watchlist/Paper Trading still render and no "Settings" sidebar item exists) — **passed live in 5.0s** on this single-display box; build green.

**UI — Watchlist merged into the Recommendations screen (2026-06-14).** Collapsed the separate **Recommendations** + **Watchlist** sidebar tabs into **one screen** (single item, still named "Recommendations", still the default landing): the action inbox cards on top, the composite Watchlist beneath them, **everything in one `ScrollView`** ("stacked scroll"). Pure view composition — `RecommendationsView` now also takes the (unchanged) `WatchlistViewModel` held in `MainSidebarView` and renders a new `WatchlistSection`; **no VM / store / engine / composer change**, so the unit suite + selection-engine golden master stay byte-for-byte. The Watchlist's macOS `Table` became a `LazyVStack` of plain `WatchlistRowView`s (new `Features/Watchlist/WatchlistSection.swift`; the old `WatchlistView.swift` deleted) — the `Table` exposed no user sorting (rows arrive pre-sorted by composite score desc), so nothing functional is lost; the row ids (`watchlist.stockcode-<TICKER>` / `watchlist.screeners-<TICKER>`) and `ScreenerIconStrip` are preserved, and `.searchable` stays scoped to the watchlist section. `SidebarItem.watchlist` + its route removed. Tests: `WatchlistUITests`/`StockDetailUITests` now act on the watchlist section of the default screen (scroll-to-reveal, since the section sits below the cards in a lazy stack); `GlobalFetchStatusUITests` screen-2 moved Watchlist→Paper Trading; `SidebarUITests` no longer asserts a Watchlist tab. **Full `AutoscreenerTests`: TEST SUCCEEDED, golden master byte-for-byte**; app launches + renders crash-free under fixtures. The UI-test runner was env-blocked this session (windows==0 — reproduces on the unchanged `SidebarUITests`, the standing caveat), so the UI suite is CI proof. Open (optional): the watchlist plain rows lose the `Table`'s column auto-sizing (fixed-width columns instead).

---

## 15. Continuous market-hours sweep + disk cache

There is **one fetch path** for the whole app: a single `DataSweepCoordinator` that fills two disk-backed stores — `ScreenerStore` (the 20 bandar screeners) and `MarketDataStore` (the Markets price quotes + the synthesised regime read, §17). Every screener tab, the composite Watchlist, and the Markets screen are thin read-only projections over those stores — they never fetch themselves. Each store survives app restarts, so a relaunch (even with the market closed) renders the last captured snapshot immediately. Crucially, **every** outgoing Stockbit request — screener page, market quote, or regime input — passes through the **same anti-burst throttle**, so the app issues one request at a time and Stockbit never sees a parallel burst.

```
DataSweepCoordinator (@MainActor, @Observable)   ← one throttle for the whole sweep
   └─ runSweep(includeIDX:)
        ├─ screeners      (IDX-session) → ScreenerStore  (snapshot per kind, as it lands)
        ├─ market quotes  (catalog)     → MarketDataStore (24h groups always; IDX groups when open)
        └─ regime          (IDX-session) → MarketDataStore (RegimeComposer; breadth derived, §17)
   └─ open → sleep 5–10 min;  closed → sleep 20–30 min;  repeat
ScreenerStore (disk-backed)            MarketDataStore (disk-backed)
   ├─ ScreenerViewModel (per tab)        ├─ MarketQuotesViewModel → store.quotes
   └─ WatchlistViewModel (composite)     └─ RegimeViewModel       → store.regimeRead
```

### 15.1 Market clock (`Core/Market/MarketClock.swift`)

Pure value type. IDX regular sessions in **Asia/Jakarta, weekdays only**: Session 1 09:00–12:00 and Session 2 13:30–15:50 (half-open, so 15:50 sharp is closed). Fetching pauses over the 12:00–13:30 lunch break. `isOpen(at:)` and `nextOpen(after:)` take an injectable clock (tested at session boundaries / lunch / weekend). **Exchange holidays are not modelled** — a holiday weekday is treated as open (documented limitation; worst case a wasted sweep returning yesterday's values).

### 15.2 Sweep loop & cadence

`start()` is idempotent (called from `ContentView` once signed in). The loop **always sweeps**, then sleeps a randomised gap: **open** → 5–10 min (full refresh); **closed** → 20–30 min (only the around-the-clock legs). `runSweep(includeIDX:)` gates the **IDX-session legs** (the 20 screeners, composite/index/sector quotes, and the regime read) on `clock.isOpen()`; the **around-the-clock legs** (global indices, commodities, FX quotes — classified by `MarketGroup.isIDXSession`) run every sweep, since those instruments keep moving after the IDX close. When closed, the IDX legs are left frozen on their last snapshot. Each request is preceded by a randomised **1000–1500 ms** throttle (first request of the sweep free); the screener leg walks every page per screener up to a 20-page safety cap and writes each `ScreenerSnapshot{config, rows, fetchedAt}` **as it lands**. `refreshNow()` forces a full sweep (IDX legs included) regardless of session, wired to every Refresh button. Mid-sweep cancellation is internal noise (partial snapshots kept, no error banner).

### 15.3 Stores & persistence

- **`Features/Screener/ScreenerStore.swift`** — `snapshots: [BandarScreenerKind: ScreenerSnapshot]` plus `lastSweepAt` and a `version` write-counter (lets the Watchlist memoise its composite). JSON at `Application Support/Autoscreener/screener-cache.json`, keyed by `kind.rawValue` so adding/removing a kind never invalidates the file (unknown keys dropped, missing kinds self-heal next sweep).
- **`Features/Markets/MarketDataStore.swift`** — `quotes: [String: CommodityQuote]` (merged so a symbol that failed a round keeps its prior value) plus `regimeRead: RegimeRead?`, `lastSweepAt`, and a `version` counter. JSON at `Application Support/Autoscreener/market-cache.json`. `CommodityQuote` and the `RegimeRead` factor types are `Codable` for this.

Both: a corrupt/missing file loads as empty.

### 15.4 Composite + veto exclusion (`Features/Watchlist/WatchlistComposer.swift`)

`compose(snapshots)` unions rows by symbol (summing per-rule weights), then **excludes** any symbol missing from an *evaluable* veto gate (a gate with a snapshot present). A veto gate with no snapshot is not enforced and surfaces a "Liquidity veto not enforced" notice instead of emptying the list. See §4.0. Each `WatchlistRow` keeps its `matchedScreeners: Set<BandarScreenerKind>` — the per-stock screener provenance the Watchlist renders as its icon column (§7.4).

### 15.5 Headless mode (tests / `-UITestFixtures`)

Under UI fixtures and unit tests the coordinator does **not** run the continuous loop and the stores start empty (no real user file is read). `start()` instead seeds the stores with a single **full** sweep (`includeIDX: true`, regardless of the real clock) over the stub services with a no-op throttle, so the screener, market, and regime surfaces render deterministically and offline.

---

## 16. Possible next milestones

Pick from the ranked list — none are in-flight.

1. **Filter editor** — let the user build / edit a `ScreenerConfig` instead of being stuck on bandar-accumulating. Needs a metric-catalog source (probably `GET /screener/preset?mobile=1`).
2. **Saved screeners list** — wire `GET /screener/templates`, `GET /screener/favorites`, `GET /screener/preset?mobile=1`. A sidebar with the user's templates + Stockbit's curated presets.
3. **Persist last-used screener config** in UserDefaults so the next launch opens straight to the user's most recent screener, not bandar-accumulating.
4. **Company detail on row click** — `GET /emitten/<TICKER>/info`, `GET /charts/<TICKER>/daily?...`, render an inline detail pane or sheet.
5. **Real-time price overlay** — the WebSocket endpoint `wss-trading.stockbit.com/ws` (and a peer at `ws3.stockbit.com`) streams price updates. The REST `emitten/{symbol}/info` snapshot (§17) is the poll-based stand-in; live ticks are still descoped (§1). Note: the WS *message* format isn't in the proxseer captures (they record only the HTTP upgrade), so building this needs a frame-level capture.
6. **Migrate the remaining JSONSerialization spots to Codable** — paywall envelope, MFA challenge/verify responses, LoginService MFA detection. Cheap follow-up now that we've seen real shapes.
7. **Macros-toolbar real-time market clock** — `GET /company-price-feed/market-time/session` + `GET /charts/ihsg/daily`. Adds context, costs little.
8. **Scheduled / background refresh** — the app is currently on-demand only (§15). A proper auto-refresh would run out-of-process (e.g. a `launchd` agent) so it fires while the app is quit, persisting snapshots for instant cold-start. The earlier in-process scheduler + on-disk snapshot cache was removed because it only fired while the app was running; revisit out-of-process if auto-refresh is wanted.
9. **Global fetch-status bar + remove per-screen refresh** *(planned, locked — see `UI-CHROME-PLAN.md`)*. The continuous sweep (§15) already keeps data fresh, so per-screen refresh controls are redundant chrome. Replace them with a single fetch/API status indicator centred in the macOS title bar (`ToolbarItem(placement: .principal)` via one shared `NavigationStack`), reading the status `DataSweepCoordinator` already publishes (`isSweeping`/`loadedScreenerCount`/`lastError`/`paywallMessage` + `MarketDataStore.lastSweepAt`). Strip refresh from all fetch-backed screens; Today's Picks + Positions to Review (engine-backed, not coordinator-routed) auto-reload on sweep completion so they don't go stale. Decisions locked in the plan doc.

---

## 17. Markets — regime banner + every-row price list

The Markets sidebar screen (`Features/Markets/`) leads with the **Market Regime banner** (the top-down risk-on / neutral / risk-off read — `idx-investing-research.md` §3) sitting beside the instruments it's derived from. The banner shows the synthesised stance + a one-line posture; tapping it pushes `RegimeBreakdownView`, the transparent factor breakdown (valuation, BI rate, US rates/dollar, global equities, foreign flow, IHSG trend, rupiah, LQ45 breadth) with the late-cycle valuation guard note. The instruments are laid out as two two-column rows over a full-width row: **row 1** is the regime banner on the left with the **Global** section of world indices (11 symbols, §17.4) — the global context the regime's *global-equities* leg is partly derived from — beside it on the right; **row 2** stacks the composite (IHSG) over the indices on the left with **Commodities** (13 symbols) over **Currencies** (5: USD/IDR, SGD/IDR, EUR/IDR, AUD/IDR, CNY/IDR) on the right; **row 3** is the IDX-IC sectors as a single full-width column (the longest IDX group, given its own row rather than crammed beside another). **Every** row carries a live last-price + signed % change. Tapping a chartable row (global/composite/index/sector) opens the shared `OHLCVChartView`; commodities/currencies have no `charts/{symbol}/daily` history, so only they don't navigate.

Price + % change on the composite/index/sector rows shipped after the original merge (2026-06-11) — they were previously plain `symbol + name` rows. The snapshot uses the same `GET /emitten/{symbol}/info` path already serving commodities (§17.1): it returns the identical price-header shape for indices and stocks, so the one sweep leg covers the whole list.

**Both the quotes and the regime read are filled by the unified sweep (§15), not by the screen.** `MarketQuotesViewModel` (`store.quotes`) and `RegimeViewModel` (`store.regimeRead`) are now thin projections over the shared `MarketDataStore`, held in `MainSidebarView` (like the screener VMs) so switching tabs preserves the binding. They no longer fetch: the `DataSweepCoordinator` prices every catalog symbol and synthesises the regime read through the shared throttle, so the Markets screen never bursts the API. On appear they just ensure the sweep is running; pull-to-refresh calls `coordinator.refreshNow()`.

**Regime breadth is derived, not fetched.** `LQ45Breadth.reading(aboveSnapshot:)` intersects `LQ45Constituents` with the `.above200MA` screener snapshot the same sweep already collects (denominator = the fixed 45), replacing the old per-constituent `charts/{symbol}/daily` fan-out. `RegimeComposer.compose(...)` is the pure synthesis the coordinator calls (lifted out of `RegimeViewModel`); it feeds `RegimeFactorBuilder` + `RegimeSynthesizer` unchanged. (`BreadthService` still exists — the Tier-A selection engine, §8, still uses it; only the regime path switched to the derived reading.) USD/IDR is read from the currency quote priced this sweep rather than re-requested.

### 17.1 Price source — `GET /emitten/{symbol}/info`

The detail-header price snapshot lives in `data` of `emitten/{symbol}/info`, **not** `company-price-feed/indicative-price-volume/{symbol}` (which returns `data:null` outside the pre-open indicative auction). Verified live 2026-06-04 on OIL/XAU/CPO/USDIDR; the same path/shape serves indices (IHSG/IDX30 verified) and sectors, which is why one service backs every Markets row. Wire-format gotchas the DTO tolerates:

| Field | Type on wire | Note |
|---|---|---|
| `price` | **string** | float-precision noise (`"95.04000091552734"`) or clean int (`"4680"`) → parse with `Double()` |
| `previous` / `change` / `volume` | **string** | `change` is signed (`"+26.44"` / `"-0.98"`) — `Double("+…")` works |
| `percentage` | **JSON number** | `-1.02` |
| `formatted_price` | string | display only, has thousands commas (`"4,493"`) — never `Double()` it |
| `value` / `average` | `"NA"` for commodities | left undecoded, can't break the decode |
| `name` / `time` | string | `"Crude Oil"` / `"Thu 14:22"` |

### 17.2 Components

```
Features/Markets/
├── MarketCatalog.swift          // global/composite/index/sector/commodity/currency MarketGroup cases (Global declared first → renders below the banner); `hasChart`; `isIDXSession` (sweep cadence, §15.2); all symbols; `grouped()`
├── CommodityModels.swift        // CommodityQuote (domain, Codable) + EmittenInfoResponseDTO + toDomain()
├── CommodityPriceService.swift  // CommodityPriceServicing; static makeEndpoint/parse; APIError→CommodityPriceError mapping (mirrors ChartService)
├── MarketDataStore.swift        // @MainActor @Observable, disk-backed (market-cache.json); quotes + regimeRead; merge-keeps-prior; written only by DataSweepCoordinator (§15.3)
├── MarketQuotesViewModel.swift  // thin projection → store.quotes; load(force:) delegates to coordinator
└── MarketsView.swift            // regime banner (→ RegimeBreakdownView push) + priced rows for every group; .hasChart rows wrapped in NavigationLink; .task ensures sweep started, .refreshable forces a sweep

Features/Regime/
├── RegimeViewModel.swift        // thin projection → store.regimeRead; load(force:) delegates to coordinator
├── RegimeComposer.swift         // pure: gathered inputs → RegimeRead (RegimeFactorBuilder + RegimeSynthesizer); called by the coordinator
├── LQ45Breadth.swift            // derives BreadthReading from the .above200MA screener snapshot (no chart fan-out)
└── RegimeBreakdownView.swift    // full factor breakdown (pushed from the banner) + RegimeColors stance/signal→Color (UI-layer; models stay UI-free)
```

DI: the coordinator gets `commodityPriceService`, `chartService`, `aggregateForeignFlowService`, `regimeSnapshotService` (all `Stub*` under `-UITestFixtures`) and writes the `MarketDataStore`. The store merges per-symbol results so a sweep that fails one symbol keeps its prior value; a missing quote renders as "—" and a missing regime read just hides the banner (graceful, no screen-level error). No view-side polling — the sweep refreshes on its cadence (§15.2) and on pull-to-refresh.

### 17.3 Commodity symbols

OIL (Crude Oil), BRENT (Brent Oil), GAS (Natural Gas), COAL-NEWCASTLE (Newcastle Coal), CPO (Palm Oil), XAU (Gold), SILVER, NICKEL, COPPER, ALUMINIUM, TIN, ZINC-COMMODITIES (Zinc), RUBBER — plus USDIDR (US Dollar / Rupiah), SGDIDR (Singapore Dollar / Rupiah), EURIDR (Euro / Rupiah), AUDIDR (Australian Dollar / Rupiah), CNYIDR (Yuan Renminbi / Rupiah) under Currencies (`type_company:"FX"`; the four non-USD pairs confirmed live 2026-06-11).

### 17.4 Global index symbols

SP500 (S&P 500), DOW30 (Dow Jones), NASDAQ (Nasdaq Composite), FTSE (FTSE 100), DAX, CAC40 (CAC 40), NIKKEI (Nikkei 225), HANGSENG (Hang Seng), KOSPI, SHANGHAI (Shanghai Composite), STI (Straits Times). Stockbit serves world indices on the same `emitten/{symbol}/info` (snapshot) and `charts/{symbol}/daily` (history) paths as IDX symbols, so they price and chart with zero new wiring. Symbols are from the Stockbit request capture (proxseer), pending live `charts/{symbol}/daily` confirmation — unlike the IDX rows verified live 2026-06-04. SP500 also backs the regime's global-equities factor (fetched in the sweep's regime leg, §15.2).

---

## 18. Paper Trading — regime-weighted 100M IDR portfolio

A persisted, mark-to-market paper account (seeded with **Rp 100,000,000**) that allocates across the composite Watchlist, sizing total equity exposure by the market regime and each name by conviction. It joins the two signals the app already produces — the conviction-scored Watchlist (§4.0/§15.4) and the regime read (§17) — and adds only an allocation + accounting layer. **It places no real orders; it is a simulation.**

The screen reads three stores and writes one: `PaperTradingStore` (the portfolio), `MarketDataStore.regimeRead` (the regime), and `ScreenerStore` (watchlist + prices). It never fetches — the unified sweep (§15) is still the only fetch path.

### 18.1 The allocation framework (the "why")

A three-layer **regime-gated, conviction-weighted, risk-capped** allocator, each layer grounded in a domain skill the project routes to:

1. **How much to deploy (Zweig — `winning-on-wall-street`).** Map `RegimeRead.score ∈ [−1,+1]` to a target equity exposure; the rest is cash. The regime read is already a Zweig-shaped composite (monetary factors `policyRate`/`usRates`/`globalDollar` + tape factors `trend`/`breadth`/`foreignFlow`/`globalEquities` + a valuation guardrail). Bands: **risk-off** (`score ≤ −0.33`) → 0–30%; **neutral** → 50–60%; **risk-on** (`score ≥ +0.33`) → up to **95%** (never 100% — a survive-first cash floor). Piecewise-linear within each band so exposure rises smoothly with conviction. A `nil` regime degrades to the neutral band.
2. **What to hold (the existing Watchlist score).** Rank veto-clean, priced `WatchlistRow`s by `score` (the tuned per-rule weighted-evidence number), take the top **N** (default 12).
3. **How much of each (Against the Gods — `against-the-gods`).** Conviction weights = `scoreᵏ` (k = `kellyFraction`, default 0.5 — √-damping, since the screener score is *evidence*, not a calibrated win-probability), normalised to the exposure, then **water-filled** under an effective per-name cap = `min(perNameCap, 1/minPositions)`. The cap both prevents one thesis from sinking the book and forces ≥ `minPositions` names once exposure is high enough (IDX names are highly correlated — correlations spike toward 1 in a crisis — so a count floor is the practical diversification lever). Targets are lot-rounded to 100 shares; deltas worth less than `rebalanceBandPct` × equity are suppressed (anti-churn).

Why a forward paper engine and **not** the existing `Backtester` (§INTEGRATION): the harness is offline, needs point-in-time history, and answers "would this config have worked?". Paper trading is forward, live-priced, single-path — so it **reuses the harness value primitives** (`Portfolio`/`Lot`/`TradeSide`/`ExecutionModel` and the avg-cost/fee math) but not the replay loop.

### 18.2 Propose-then-confirm

`generatePlan()` runs the pure `AllocationEngine.plan(state:watchlist:regime:prices:exitDecisions:config:)` → an `AllocationPlan` of `AllocationLine`s (symbol, side, current/target/delta shares, price, est value, target weight, and a human **rationale** string — the same transparency ethos as `RegimeFactor.detail`). Nothing executes until the user clicks **Execute**: `PaperTradingStore.apply(plan:)` books **sells before buys** (to free cash), pricing each fill through `ExecutionModel.standardIDX` (lot 100, buy 0.15%, sell 0.25%, slippage 0.05%), appends `PaperTrade`s, and persists. **Reset** returns the account to its 100M seed.

**Gate-5 exit overlay (`exitDecisions`).** The allocator honours the selection engine's sell-side discipline (Gate-5, `INTEGRATION.md`): `exitDecisions` is a `[symbol: ExitAction]` map (defaulted empty ⇒ regime-only behaviour, byte-for-byte). `.exit` bars a name from the buy candidates **and** forces any held lot to a full sale, overriding the anti-churn band (a broken thesis isn't churn); `.trim` caps the target at the current size (`min(natural, current)` — never adds, but the natural downward rebalance still applies); `.hold`/absent imposes no constraint. The map is sourced from `ExitDecisionsStore` (see §18.3), so a flagged name can't be re-bought on the next rebalance.

### 18.3 Components

```
Features/PaperTrading/
├── Models/PaperTradingModels.swift  // PaperPosition, PaperTrade, PaperPortfolioState (seed/equity/P&L + avg-cost fill math mirroring Portfolio.apply), AllocationConfig (.standard: Zweig bands + caps + Kelly + score→exposure map), AllocationPlan/AllocationLine
├── AllocationEngine.swift           // pure enum (like RegimeSynthesizer): the 3-layer allocator, zero I/O
├── PaperTradingStore.swift          // @MainActor @Observable, disk-backed (paper-trading-cache.json); apply(plan:)/reset; version bump; same DiskModel/atomic-write/load-on-init pattern as MarketDataStore
├── PaperTradingViewModel.swift      // thin projection joining the three stores; equity/cash/P&L/holdings/trades; generatePlan (reads ExitDecisionsStore for the Gate-5 overlay)/execute/reset
└── PaperTradingView.swift           // header (equity, cash, P&L, regime badge + target exposure), proposed-plan table w/ Execute, holdings, trade log; accessibility ids (PaperTradingView, PaperTradingGenerateButton, PaperTradingExecuteButton, PaperTradingPlanRow_<SYM>, PaperTradingHoldingRow_<SYM>)

Features/Selection/ExitDecisionsStore.swift  // @MainActor @Observable, by-ticker → ExitAction cache (mirror of RecommendationsStore). Written by PositionReviewViewModel on each review; read by PaperTradingViewModel.generatePlan. Lets the allocator act on Gate-5 verdicts without re-running the expensive holdings review per rebalance.
```

**Persistence:** JSON at `Application Support/Autoscreener/paper-trading-cache.json`; a fresh account (no file) is seeded to 100M; a corrupt/missing file keeps the seed.

**DI & headless:** `AppDependencies` builds the store (`loadFromDisk: !headless`, so fixtures/tests start from a clean seed, never a real user's file). `MainSidebarView` holds the VM (preserving the pending plan across tab switches) and adds the sidebar row + detail arm. Under `-UITestFixtures` the seeded screener rows carry a `lastPrice` so the engine has prices to size against.

**Diversification note:** v1 enforces a per-name cap + position-count floor; a **per-sector** cap is deferred (`WatchlistRow` carries no sector). Names absent from every current screener snapshot have no `lastPrice` and are skipped (never filled at a stale cost basis).
