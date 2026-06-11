# Autoscreener — Spec

macOS-native client for running Stockbit screeners against the IDX market. Logs in to `exodus.stockbit.com`, manages access/refresh tokens transparently, lets the user describe a screen, fires it, and renders the results in a sortable table.

Target: macOS 15.0+ (Sequoia). Stack: SwiftUI, `@Observable`, `URLSession` async/await, Keychain, no third-party deps.

---

## 1. Scope (v1)

- [x] **Settings → Account**: username + password `TextField`s, "Sign in" button. Credentials never persisted in plaintext; tokens stored in Keychain.
- [x] **Auth pipeline**: `POST /login/v6/username` → store access + refresh JWTs → pre-flight refresh on `expired_at` proximity → 401 backstop via `POST /login/refresh` → silent retry.
- [x] **New-device MFA**: detect `multi_factor` envelope, walk `/mfa/verification/v1/challenge/{start,otp/send,otp/verify}` then `/login/v6/new-device/verify` — sequential email → phone OTPs, auto-sent on the server's `default_channel`.
- [x] **Screener run**: fifteen canned screener templates (Bandar Accumulating, Bandar Above MA20, Bandar Shift Today, Accum/Dist Positive, 1M / 6M / 3M Net Foreign Flow, Foreign Buy Streak ≥5, Fresh Foreign Buy, Frequency Spike, Volume Spike, Above 50MA, Above 200MA, Liquidity Floor, Intraday Liquidity) — `GET /screener/templates/{id}` for page 1, `POST /screener/templates` with `save:"0"` for pages ≥ 2.
- [x] **Watchlist (composite)**: union of all twenty screeners' rows, scored by per-rule weight (`bandar-master.json`), sorted desc. The two liquidity rules are *veto gates*: stocks missing from either evaluable gate are **excluded** from the composite entirely (hard-AND), not tagged.
- [x] **Continuous market-hours sweep + disk cache** (§15): while the IDX market is open, a single coordinator sweeps all twenty screeners (bandar-accum → intraday-liquidity, 1–1.5 s throttle between each) then waits a random 5–10 min and repeats, writing each result into a disk-persisted `ScreenerStore`. Every screener tab and the Watchlist read from that cache — when the market is closed (or on a cold relaunch), they render the last persisted snapshot with no network. Refresh forces an immediate sweep regardless of session.
- [ ] **Today's Picks**: the Tier-A selection screen is **hidden from the sidebar for now** (feature code retained; the app lands on the Watchlist).
- [x] **Results table**: SwiftUI `Table` with sortable columns (symbol, name, + 1–2 metric columns depending on the screener's `sequence`).
- [x] **Pagination**: increment `page` in the request body for "Load more".
- [x] **Stock-code search** (§7.3): a `.searchable` toolbar field on the Liquidity Floor, Intraday Liquidity, and Watchlist tabs filters rows by ticker (case-insensitive substring on the symbol). On the two paginated screener tabs, entering a term auto-loads all remaining pages first, so a match is never hidden behind lazy pagination; the Watchlist already holds the complete set.
- [x] **Network log panel** in Settings — live request/response trace with redaction of `password`, `otp`, `*_token`, `authorization`.
- [x] **Markets — regime banner + every-row price list** (§17): the Markets screen opens with the **Market Regime banner** (risk-on / neutral / risk-off read; tap → full factor breakdown), then a **Global** section of world indices (11: S&P 500, Dow Jones, Nasdaq, FTSE 100, DAX, CAC 40, Nikkei 225, Hang Seng, KOSPI, Shanghai, Straits Times) directly below it, then the composite (IHSG), indices, and IDX-IC sectors plus **Commodities** (13: Crude Oil, Brent, Natural Gas, Newcastle Coal, Palm Oil, Gold, Silver, Nickel, Copper, Aluminium, Tin, Zinc, Rubber) and **Currencies** (5: USD/IDR, SGD/IDR, EUR/IDR, AUD/IDR, CNY/IDR) — **every row** showing a live last-price + signed % change from `GET /emitten/{symbol}/info` (the same snapshot serves global/indices/sectors as commodities). Loaded on appear, pull-to-refresh, per-symbol failure tolerated. Tapping a chartable row (global/composite/index/sector) opens the existing OHLCV chart; commodities/currencies don't navigate.
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

**Column widths:** `No` and `Symbol` are pinned to fixed widths (`.width(44)` and `.width(60)`) rather than flexible min/ideal ranges — the row index never exceeds the ~900-stock IHSG universe (4 digits) and IDX tickers are 4–5 letters, so neither needs to grow. This keeps both columns tight and hands the freed horizontal space to `Name` and the metric columns. The same widths apply in the Watchlist table (§15), which shares the column layout.

The `Last` / `Δ%` columns from the original sketch were removed — Stockbit's `screener/templates` response doesn't carry intraday price for metric-only filters (those come from `/company-price-feed`, separate feature).

### 7.1 No view-side pagination (superseded by the sweep cache)

Screener tabs no longer paginate at the view layer. The sweep coordinator already walks every page per screener (page 1 via `GET`, pages 2+ via `POST`, terminating on empty / partial-page / total / a 20-page safety cap) and stores the **full result set** as one `ScreenerSnapshot`. A tab renders all rows from that snapshot at once; there is no `loadMore`/`rowDidAppear`. Pagination end-of-list detection now lives in `ScreenerSweepCoordinator.fetchAll` (see §15).

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
- `CommodityPriceServiceTests` — `emitten/{symbol}/info` endpoint shape; parse of live OIL/XAU/CPO captures (string vs JSON-number fields, signed `change`, comma-grouped `formatted_price`, integer-string price, `"NA"` value/average tolerance); non-numeric-price + malformed-JSON throws; error mapping through a real `APIClient` + `StubSession` (unauthorized / paywall 403 / malformed / happy path)
- `MarketQuotesViewModelTests` — fan-out populates all quotes; **default catalog covers the chartable groups too** (composite/indices/sectors, not just commodities/currencies); **partial failure** keeps the other rows; **total failure** sets a screen error; reload-skip when loaded; force-reload refetches; retry after total failure
- `MarketCatalogTests` — declaration order (`.global` first, then `.composite`…`.currency`), all 11 global indices present + chartable, all 18 commodity/currency symbols present, all 11 IDX-IC sectors, all 5 currency pairs (USD/IDR, SGD/IDR, EUR/IDR, AUD/IDR, CNY/IDR)

**UI verification.** Confirm UI changes with XCUITest under `-UITestFixtures`, never via the Accessibility API or screenshot scripts (flaky on multi-display macOS). `AutoscreenerUITests`:
- `StockDetailUITests` — tap a stock code → financial-detail flow (report/period switching)
- `MarketsUITests` — sidebar → Markets → Commodities/Currencies sections render with stubbed price + % change; Global section header + an SP500 priced row render; composite/index/sector rows also render as priced rows (`MarketsPricedRow.<symbol>`); chartable rows still navigate while commodities/currencies don't
- `RegimeUITests` — sidebar → Markets → regime banner shows the (deterministic Neutral) stance → tap → full factor breakdown (valuation / BI rate / LQ45 breadth rows)

Both guard `XCTSkipIf(NSScreen.screens.count > 1)` — they pass on single-display/CI and skip on multi-display dev machines, where XCUITest can't snapshot a window on another Space. Full sign-in remains a real-network smoke (run manually).

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

---

## 15. Continuous market-hours sweep + disk cache

There is **one fetch path**: a `ScreenerSweepCoordinator` that fills a disk-backed `ScreenerStore`. Every screener tab and the composite Watchlist are thin read-only projections over that store — they never fetch themselves. The store survives app restarts, so a relaunch (even with the market closed) renders the last captured snapshot immediately.

```
ScreenerSweepCoordinator (@MainActor, @Observable)
   └─ MarketClock.isOpen → run full fan-out (throttle 1–1.5 s/screener)
        └─ writes each kind's ScreenerSnapshot into ScreenerStore as it lands
        └─ persists the store to disk after the sweep
        └─ sleep random 5–10 min → repeat;  closed → sleep until next open
ScreenerStore (@MainActor, @Observable, disk-backed)  ← single source of truth
   ├─ ScreenerViewModel (per tab)  → renders snapshots[kind]
   └─ WatchlistViewModel           → WatchlistComposer over all snapshots (veto-excluded)
```

### 15.1 Market clock (`Core/Market/MarketClock.swift`)

Pure value type. IDX regular sessions in **Asia/Jakarta, weekdays only**: Session 1 09:00–12:00 and Session 2 13:30–15:50 (half-open, so 15:50 sharp is closed). Fetching pauses over the 12:00–13:30 lunch break. `isOpen(at:)` and `nextOpen(after:)` take an injectable clock (tested at session boundaries / lunch / weekend). **Exchange holidays are not modelled** — a holiday weekday is treated as open (documented limitation; worst case a wasted sweep returning yesterday's values).

### 15.2 Sweep loop & cadence

`start()` is idempotent (called from `ContentView` once signed in). The loop: **open** → `runSweep()` then sleep a random **5–10 min**; **closed** → sleep until `nextOpen` (capped at 15 min so it re-checks). `runSweep()` does one paywall increment, then fetches the twenty screeners in `fanOutOrder` (bandar-accum → intraday-liquidity), each request preceded by a randomised **1000–1500 ms** throttle (first request free), walking every page per screener up to a 20-page safety cap. Each screener's `ScreenerSnapshot{config, rows, fetchedAt}` is written to the store **as it lands**, so all surfaces fill in progressively. `refreshNow()` runs one sweep immediately regardless of session (wired to every Refresh button). Mid-sweep cancellation is treated as internal noise (partial snapshots kept, no error banner).

### 15.3 Store & persistence (`Features/Screener/ScreenerStore.swift`)

`snapshots: [BandarScreenerKind: ScreenerSnapshot]` plus `lastSweepAt` and a `version` write-counter (lets the Watchlist memoise its composite instead of recomputing per render). Persisted as JSON at `Application Support/Autoscreener/screener-cache.json`, keyed by `kind.rawValue` so adding/removing a kind never invalidates the file (unknown keys dropped, missing kinds self-heal next sweep). A corrupt/missing file loads as empty.

### 15.4 Composite + veto exclusion (`Features/Watchlist/WatchlistComposer.swift`)

`compose(snapshots)` unions rows by symbol (summing per-rule weights), then **excludes** any symbol missing from an *evaluable* veto gate (a gate with a snapshot present). A veto gate with no snapshot is not enforced and surfaces a "Liquidity veto not enforced" notice instead of emptying the list. See §4.0.

### 15.5 Headless mode (tests / `-UITestFixtures`)

Under UI fixtures and unit tests the coordinator does **not** run the continuous loop and the store starts empty (no real user file is read). `start()` instead seeds the store with a single sweep over the stub services (with a no-op throttle), so the UI renders deterministically and offline.

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

---

## 17. Markets — regime banner + every-row price list

The Markets sidebar screen (`Features/Markets/`) opens with the **Market Regime banner** (the top-down risk-on / neutral / risk-off read — `idx-investing-research.md` §3) sitting atop the instrument list it's derived from. The banner shows the synthesised stance + a one-line posture; tapping it pushes `RegimeBreakdownView`, the transparent factor breakdown (valuation, BI rate, US rates/dollar, global equities, foreign flow, IHSG trend, rupiah, LQ45 breadth) with the late-cycle valuation guard note. Directly below the banner sits a **Global** section of world indices (11 symbols, §17.4) — the global context the regime's *global-equities* leg is partly derived from — followed by **every** other row: the composite (IHSG), indices, IDX-IC sectors, **Commodities** (13 symbols) and **Currencies** (5: USD/IDR, SGD/IDR, EUR/IDR, AUD/IDR, CNY/IDR), each carrying a live last-price + signed % change. Tapping a chartable row (global/composite/index/sector) opens the shared `OHLCVChartView`; commodities/currencies have no `charts/{symbol}/daily` history, so only they don't navigate.

Price + % change on the composite/index/sector rows shipped after the original merge (2026-06-11) — they were previously plain `symbol + name` rows. The snapshot uses the same `GET /emitten/{symbol}/info` path already serving commodities (§17.1): it returns the identical price-header shape for indices and stocks, so one fan-out covers the whole list (~35 concurrent requests, in line with the regime breadth fan-out).

The regime read and the markets list were **merged into this one screen** (2026-06-11) — previously two separate sidebar entries under "Markets". `RegimeViewModel` and `MarketQuotesViewModel` are now held in `MainSidebarView` (like the screener VMs) so switching tabs preserves loaded data and doesn't re-fire the expensive regime fetch (a `charts/{symbol}/daily` request per LQ45 constituent for breadth) on every visit; both load concurrently on appear and force-refresh together on pull-to-refresh.

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
├── MarketCatalog.swift          // global/composite/index/sector/commodity/currency MarketGroup cases (Global declared first → renders below the banner); all symbols; `grouped()`
├── CommodityModels.swift        // CommodityQuote (domain) + EmittenInfoResponseDTO + toDomain()
├── CommodityPriceService.swift  // CommodityPriceServicing; static makeEndpoint/parse; APIError→CommodityPriceError mapping (mirrors ChartService)
├── MarketQuotesViewModel.swift  // @MainActor @Observable; concurrent withTaskGroup fan-out over MarketCatalog.all; per-symbol failure tolerance
└── MarketsView.swift            // regime banner (→ RegimeBreakdownView push) + priced rows for every group; .hasChart rows wrapped in NavigationLink; concurrent regime+quotes load on .task / .refreshable

Features/Regime/
└── RegimeBreakdownView.swift    // full factor breakdown (pushed from the banner) + RegimeColors stance/signal→Color (UI-layer; models stay UI-free)
```

DI: `AppDependencies.commodityPriceService` (`StubCommodityPriceService` under `-UITestFixtures`). The VM merges per-symbol results so a refresh that fails one symbol keeps its prior value; a screen-level error surfaces only when **every** symbol fails (leaving `hasLoaded` false so the next appearance retries). No auto-polling — refresh is on-appear + pull-to-refresh.

### 17.3 Commodity symbols

OIL (Crude Oil), BRENT (Brent Oil), GAS (Natural Gas), COAL-NEWCASTLE (Newcastle Coal), CPO (Palm Oil), XAU (Gold), SILVER, NICKEL, COPPER, ALUMINIUM, TIN, ZINC-COMMODITIES (Zinc), RUBBER — plus USDIDR (US Dollar / Rupiah), SGDIDR (Singapore Dollar / Rupiah), EURIDR (Euro / Rupiah), AUDIDR (Australian Dollar / Rupiah), CNYIDR (Yuan Renminbi / Rupiah) under Currencies (`type_company:"FX"`; the four non-USD pairs confirmed live 2026-06-11).

### 17.4 Global index symbols

SP500 (S&P 500), DOW30 (Dow Jones), NASDAQ (Nasdaq Composite), FTSE (FTSE 100), DAX, CAC40 (CAC 40), NIKKEI (Nikkei 225), HANGSENG (Hang Seng), KOSPI, SHANGHAI (Shanghai Composite), STI (Straits Times). Stockbit serves world indices on the same `emitten/{symbol}/info` (snapshot) and `charts/{symbol}/daily` (history) paths as IDX symbols, so they price and chart with zero new wiring. Symbols are from the Stockbit request capture (proxseer), pending live `charts/{symbol}/daily` confirmation — unlike the IDX rows verified live 2026-06-04. SP500 also backs the regime's global-equities factor (`RegimeViewModel`).
