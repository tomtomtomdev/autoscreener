# Autoscreener — Spec

macOS-native client for running Stockbit screeners against the IDX market. Logs in to `exodus.stockbit.com`, manages access/refresh tokens transparently, lets the user describe a screen, fires it, and renders the results in a sortable table.

Target: macOS 15.0+ (Sequoia). Stack: SwiftUI, `@Observable`, `URLSession` async/await, Keychain, no third-party deps.

---

## 1. Scope (v1)

- [x] **Settings → Account**: username + password `TextField`s, "Sign in" button. Credentials never persisted in plaintext; tokens stored in Keychain.
- [x] **Auth pipeline**: `POST /login/v6/username` → store access + refresh JWTs → pre-flight refresh on `expired_at` proximity → 401 backstop via `POST /login/refresh` → silent retry.
- [x] **New-device MFA**: detect `multi_factor` envelope, walk `/mfa/verification/v1/challenge/{start,otp/send,otp/verify}` then `/login/v6/new-device/verify` — sequential email → phone OTPs, auto-sent on the server's `default_channel`.
- [x] **Screener run**: fifteen canned screener templates (Bandar Accumulating, Bandar Above MA20, Bandar Shift Today, Accum/Dist Positive, 1M / 6M / 3M Net Foreign Flow, Foreign Buy Streak ≥5, Fresh Foreign Buy, Frequency Spike, Volume Spike, Above 50MA, Above 200MA, Liquidity Floor, Intraday Liquidity) — `GET /screener/templates/{id}` for page 1, `POST /screener/templates` with `save:"0"` for pages ≥ 2.
- [x] **Watchlist (composite)**: union of all fifteen screeners' rows, scored by per-rule weight (`bandar-master.json`), sorted desc. The two liquidity rules are *veto gates*: stocks missing from either are flagged "ILLIQUID" in red regardless of bandar score.
- [x] **Configurable refresh schedule** (§16): on-demand / 15-min / hourly / daily 08:45 (IDX open) / daily 16:15 (IDX close). Auto-refresh modes persist per-screener + watchlist snapshots to Application Support and seed instant boot.
- [x] **Results table**: SwiftUI `Table` with sortable columns (symbol, name, + 1–2 metric columns depending on the screener's `sequence`).
- [x] **Pagination**: increment `page` in the request body for "Load more".
- [x] **Stock-code search** (§7.3): a `.searchable` toolbar field on the Liquidity Floor, Intraday Liquidity, and Watchlist tabs filters rows by ticker (case-insensitive substring on the symbol). On the two paginated screener tabs, entering a term auto-loads all remaining pages first, so a match is never hidden behind lazy pagination; the Watchlist already holds the complete set.
- [x] **Network log panel** in Settings — live request/response trace with redaction of `password`, `otp`, `*_token`, `authorization`.
- [x] **Build DMG**: `scripts/build_dmg.sh` produces a notarisable `Autoscreener.dmg`.

Out of scope for v1: charting, real-time WebSocket, saving custom templates, multi-account, paywall enforcement (we hit `paywall/eligibility/check` and surface the result, but don't gate UI), filter-builder UI (canned preset only).

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
| Watchlist | — | composite of all fifteen above, deduped by symbol | — | sum (max 17.5) |

† *Veto gate* — `bandar-master.json` declares these `veto: true`. Matching contributes `weight` to the composite score normally (weighted-OR), but **missing from either** trips a hard-AND "ILLIQUID" flag (red) on the row in the Watchlist tab, regardless of bandar score. The flag's tooltip lists which gate(s) the row failed.

> **A gate only vetoes when it was actually evaluated.** The flag is materialized onto each row (`WatchlistRow.failedVetoGates`) at composition time, restricted to veto gates that were *freshly read* this generation — i.e. fetched successfully in the live fan-out, or present in the dominant cache generation when aggregating. A veto gate whose cache went stale or whose fetch failed is **not** enforced (and the status bar shows a "Liquidity veto not enforced" notice), rather than blanket-flagging every row ILLIQUID. This is what makes the union-from-cache aggregation safe: if the scheduler refreshes 14/15 screeners but the 15th gate cache is stale, that gate simply isn't applied — the watchlist isn't poisoned. Without this, a single missing/stale liquidity cache flags the entire watchlist illiquid.

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

The `Last` / `Δ%` columns from the original sketch were removed — Stockbit's `screener/templates` response doesn't carry intraday price for metric-only filters (those come from `/company-price-feed`, separate feature).

### 7.1 Auto-pagination

No "Load more" button. SwiftUI's `.onAppear` is attached to the **last row's Symbol cell**: when it scrolls into view, `vm.rowDidAppear(at: rows.count - 1)` fires, the ViewModel guards (`hasMore`, `!isLoading`) collapse repeat triggers (Table reuses cells) into a single network call, and `loadMore()` increments `page` and POSTs to `/screener/templates`.

End-of-list detection in `ScreenerViewModel.updateServerSaysDone`:
- empty page returned → done (definitive),
- `total` supplied and `rows.count >= total` → done,
- otherwise: partial page (< `config.limit` rows) → done (heuristic).

Once `serverSaysDone == true`, `hasMore` is permanently false until a fresh `run()` / `bootstrap()` resets it.

### 7.2 Toolbar + status bar

- Header row: `config.name` (template name) and `config.universe.scope`, plus a `ProgressView` while a fetch is in flight. No action buttons — the screener auto-runs on launch and auto-paginates on scroll, and the network log lives in Settings.
- Status bar (below the table): "N of T rows · page P" when total is known, "N rows · page P" otherwise. With an active search it switches to "N of M rows match".

### 7.3 Stock-code search

The **Liquidity Floor** and **Intraday Liquidity** tabs — and the **Watchlist** (§15) — expose a `.searchable` toolbar field. It's opt-in per tab via `ScreenerView(enableSearch:)` (the Watchlist always has it), so the other 18 screener tabs that share `ScreenerView`/`ScreenerViewModel` are unaffected. Matching is a case-insensitive substring over the row's `symbol` **only** (company name is not matched); a blank/whitespace query shows everything. The view renders `vm.visibleRows` (the filtered set) instead of `vm.rows`, and a no-match search shows `ContentUnavailableView.search`.

The filter is a single shared implementation: `Array.filteredBySymbol(_:)` on the `SymbolSearchable` protocol, to which both `ScreenerRow` and `WatchlistRow` conform — so the two screener tabs and the Watchlist share one tested code path (`SymbolSearch.swift`).

Because the two screener tabs are lazily paginated, a naive filter over loaded rows would miss a symbol sitting on a not-yet-scrolled page. So the first non-empty keystroke kicks `ScreenerViewModel.loadAllForSearch()`, which walks `loadMore()` until `hasMore` is false — eagerly pulling every remaining page before filtering. A re-entrancy guard (`isExhaustingPages`) collapses rapid keystrokes into one sweep, and once all pages are in it's a no-op. The Watchlist needs none of this — it already holds the full aggregated set, so its `visibleRows` filter is always complete. Search terms are transient UI state, never persisted to snapshots.

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

137 unit tests at present (`xcodebuild -only-testing:AutoscreenerTests test`). Coverage:

- `JWTTests` — payload base64url decode, `isExpiring` window
- `LoginServiceTests` — request body + headers, three response envelopes (trusted-device, new-device, flat), `expired_at` parsing, MFA outcome detection, 401 → `invalidCredentials`, refresh bearer attach
- `DeviceVerificationServiceTests` — request shapes for all four MFA endpoints, channel/target parsing from `supporting_data.otp`, `next_challenge` detection, error mapping (invalid OTP, challenge expired)
- `APIClientAuthInterceptorTests` — bearer attach, 401-then-refresh-then-retry, refresh-failure wipes tokens, **pre-flight refresh fires within the 60s window**, dead refresh wipes Keychain
- `SettingsViewModelTests` — happy sign-in, invalid creds surface, sign-out toggle, **multi-step MFA flow chains email → phone → completes**, invalid OTP stays in verification phase, expired challenge bounces back
- `ScreenerServiceWireFormatTests` — exact double-encoded `filters`/`universe` strings vs the captured fixture; pagination
- `ScreenerServiceParseTests` — three response envelope shapes + values-array / id-keyed metric layouts + missing-values tolerance
- `ScreenerViewModelTests` — run, loadMore, clear-on-rerun, error mapping
- `NetworkLogRedactionTests` — every sensitive key gets `***`, case-insensitive
- `ScreenerScheduleTests` — next-fire-date math for each cadence (15-min/hourly/daily 08:45 + 16:15 WIB), stale-window durations
- `ScreenerSnapshotStoreTests` — round-trip per-screener + watchlist JSON in a temp dir, missing-file returns nil, disabled flag suppresses writes
- `ScreenerViewModelSnapshotTests` — seeded snapshot renders without hitting the network; first-run with no snapshot falls through to GET; refresh writes back; disabled persistence is no-op
- `ScreenerSchedulerTests` — `.onDemand` leaves `nextFireDate` nil, `stop()` cancels the loop, instant sleep fires refresh, switching to `.onDemand` halts the cycle
- `SymbolSearchTests` — shared `filteredBySymbol`: blank/whitespace passthrough, case-insensitivity, substring match, no-match-empty, symbol-not-company-name, surrounding-whitespace trim
- `ScreenerSearchTests` — `visibleRows` tracks `searchText`; `loadAllForSearch()` exhausts every remaining page and leaves `hasMore == false`
- `WatchlistSearchTests` — `visibleRows` filters by symbol (blank passthrough, case-insensitive, symbol-not-name)

UI tests in `AutoscreenerUITests` cover launch only; full sign-in is a real-network smoke (run manually).

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

137 unit tests passing. Next milestone in §16.

---

## 15. Refresh schedule and persistence

User-selectable cadence applied uniformly across all fifteen screener tabs + the composite Watchlist. Picker lives in Settings (⌘,).

### 15.1 Modes

| Mode | Trigger | Stale window |
|---|---|---|
| **On demand** | Tab reveal (first run) + Refresh button. No persistence. | — |
| **Every 15 minutes** | Next :00 / :15 / :30 / :45 wall-clock. | 15 min |
| **Every hour** | Next :00. | 60 min |
| **Daily 08:45 (IDX open)** | 08:45 **Asia/Jakarta** (WIB / UTC+7). | 24 h |
| **Daily 16:15 (IDX close)** | 16:15 **Asia/Jakarta**. | 24 h |

### 15.2 Lifecycle

```
ScreenerScheduler.start(refresh:)
  while !cancelled:
    next = preferences.schedule.nextFireDate(after: now)
    sleep(until: next)
    await refresh()                          // → WatchlistViewModel.scheduledRefresh()
      ├─ refreshScreenerCaches()  fan-out, persist 15× per-screener snapshots
      └─ aggregateFromCache()     union caches → watchlist.json (no network)
```

**Fetch/aggregate split (non-onDemand only).** The `refresh` closure handed in by `MainSidebarView` calls `watchlistVM.scheduledRefresh()`, which is two phases:

1. `refreshScreenerCaches()` — the throttled 15-way fan-out (1000–1500 ms between requests, one paywall increment). Writes each screener's full config + rows to `~/Library/Application Support/Autoscreener/snapshots/<templateID>.json`. **This is the only place the network is touched under a schedule.**
2. `aggregateFromCache()` — composes the Watchlist by unioning those per-screener caches locally (no network, no throttle, no paywall) and writes `watchlist.json`.

Because the scheduler keeps the per-screener caches fresh, the Watchlist's own reveal/refresh never pays the sequential fetch — it just re-unions cache. This is the "screeners cache; watchlist aggregates" model: it decouples the slow fan-out (background, scheduled) from the composite build (instant, on-screen).

Cadence changes restart the loop immediately (`MainSidebarView.onChange` observer). `.onDemand` cancels and parks the scheduler.

### 15.3 Bootstrap with snapshots

- `ScreenerViewModel.autoRunIfNeeded`: if a snapshot exists, render rows + config + `lastFetchedAt` immediately and skip the GET. Otherwise fall through to the existing `GET /screener/templates/{id}` bootstrap.
- `WatchlistViewModel.autoRunIfNeeded`: if `watchlist.json` exists, render it and skip everything else. Otherwise `refresh()`.
- `WatchlistViewModel.refresh()` routes on the active schedule:
  - **Non-onDemand** → `aggregateFromCache()` (instant local union). Cold start (no per-screener caches yet) transparently falls back to one `scheduledRefresh()` populate.
  - **On-demand** → `liveFanOut()` (the legacy throttled fetch + compose-in-memory), since no scheduler is filling caches.
- Settings' **Refresh now** forces a full `scheduledRefresh()` (refetch every cache, then aggregate). The Watchlist toolbar button uses `refresh()` (cache union under a schedule).

This makes the first scheduled fetch the only one that pays the full fifteen-call latency cost — subsequent launches, tab switches, and watchlist refreshes are instant cache reads.

### 15.4 Persistence file layout

```
~/Library/Application Support/Autoscreener/snapshots/
├── 6676213.json   Bandar Accumulating          { templateID, config, rows[], total?, fetchedAt }
├── 6676217.json   Bandar Above MA20
├── 6676221.json   Bandar Shift Today
├── 6676223.json   Accum/Dist Positive
├── 6676225.json   1M Net Foreign Flow
├── 6676228.json   6M Net Foreign Flow
├── 6676231.json   3M Net Foreign Flow
├── 6676235.json   Foreign Buy Streak ≥5
├── 6676238.json   Fresh Foreign Buy
├── 6676260.json   Frequency Spike
├── 6676263.json   Volume Spike
├── 6676264.json   Above 50MA
├── 6676268.json   Above 200MA
├── 6676314.json   Liquidity Floor       (veto gate)
├── 6676320.json   Intraday Liquidity    (veto gate)
└── watchlist.json                             { rows[], fetchedAt }
```

Each file is ≤ ~10 KB. Writes are atomic (`.atomic` option). Reads are tolerant of missing/corrupt files (return nil, callers fall back to bootstrap).

### 15.5 Scope caveat

**macOS apps don't run when quit.** The scheduler is in-process, so scheduled refreshes only fire while Autoscreener is the front/background app. On launch we boot from the most recent snapshot; any catch-up fetch happens on the next user interaction (Refresh button) or the next scheduled fire while running. Out-of-process scheduling via a `launchd` agent is deferred to a future milestone.

### 15.6 Settings UI

The picker, "Last refresh" / "Next refresh" labels (driven by `ScreenerScheduler.lastFireDate` / `nextFireDate`), and a "Refresh now" button live in `AppSettingsView`. "Refresh now" posts `Notification.Name.autoscreenerRefreshNow`, which the sidebar observes to forward the call to the live `WatchlistViewModel`.

Every screener tab and the Watchlist tab also expose their own Refresh button in their toolbar, plus an "as of HH:mm" badge showing when the displayed rows landed.

---

## 16. Possible next milestones

Pick from the ranked list — none are in-flight.

1. **Filter editor** — let the user build / edit a `ScreenerConfig` instead of being stuck on bandar-accumulating. Needs a metric-catalog source (probably `GET /screener/preset?mobile=1`).
2. **Saved screeners list** — wire `GET /screener/templates`, `GET /screener/favorites`, `GET /screener/preset?mobile=1`. A sidebar with the user's templates + Stockbit's curated presets.
3. **Persist last-used screener config** in UserDefaults so the next launch opens straight to the user's most recent screener, not bandar-accumulating.
4. **Company detail on row click** — `GET /emitten/<TICKER>/info`, `GET /charts/<TICKER>/daily?...`, render an inline detail pane or sheet.
5. **Real-time price overlay** — the WebSocket endpoint `wss-jkt.trading.stockbit.com/ws` (and a peer at `ws3.stockbit.com`) streams price updates. Currently descoped (§1).
6. **Migrate the remaining JSONSerialization spots to Codable** — paywall envelope, MFA challenge/verify responses, LoginService MFA detection. Cheap follow-up now that we've seen real shapes.
7. **Macros-toolbar real-time market clock** — `GET /company-price-feed/market-time/session` + `GET /charts/ihsg/daily`. Adds context, costs little.
