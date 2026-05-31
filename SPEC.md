# Autoscreener — Spec

macOS-native client for running Stockbit screeners against the IDX market. Logs in to `exodus.stockbit.com`, manages access/refresh tokens transparently, lets the user describe a screen, fires it, and renders the results in a sortable table.

Target: macOS 15.0+ (Sequoia). Stack: SwiftUI, `@Observable`, `URLSession` async/await, Keychain, no third-party deps.

---

## 1. Scope (v1)

- [x] **Settings → Account**: username + password `TextField`s, "Sign in" button. Credentials never persisted in plaintext; tokens stored in Keychain.
- [x] **Auth pipeline**: `POST /login/v6/username` → store access + refresh JWTs → pre-flight refresh on `expired_at` proximity → 401 backstop via `POST /login/refresh` → silent retry.
- [x] **New-device MFA**: detect `multi_factor` envelope, walk `/mfa/verification/v1/challenge/{start,otp/send,otp/verify}` then `/login/v6/new-device/verify` — sequential email → phone OTPs, auto-sent on the server's `default_channel`.
- [x] **Screener run**: canned "Bandar Value > Bandar Value MA 20" preset → `POST /screener/templates` with `save:"0"` → render rows.
- [x] **Results table**: SwiftUI `Table` with sortable columns (symbol, name, + selected metrics).
- [x] **Pagination**: increment `page` in the request body for "Load more".
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

```
POST https://exodus.stockbit.com/screener/templates
Authorization: Bearer <access>
Content-Type: application/json

{
  "save": "0",
  "limit": 25,
  "page": <1-based>,
  "ordercol": 2,
  "ordertype": "desc",
  "sequence": "14399,14426",
  "filters": "<stringified JSON array>",
  "universe": "<stringified JSON object>",
  "type": "TEMPLATE_TYPE_CUSTOM",
  "name": "<name>",
  "description": ""
}
```

Notes (full details in memory `project_autoscreener_screener_api.md`):
- `filters` and `universe` are **double-encoded JSON strings** — match exactly.
- `sequence` = comma-separated metric IDs → drives returned columns.
- Pagination = bump `page`. Response shape TBD at integration; expect rows + total.

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

`SwiftUI.Table` with `sortOrder` binding, e.g.:

```swift
Table(rows, selection: $selection, sortOrder: $vm.sort) {
  TableColumn("Symbol", value: \.symbol)
  TableColumn("Name",   value: \.name)
  TableColumn("Bandar Value")      { Text(format($0.col(14399))) }
  TableColumn("Bandar Value MA 20"){ Text(format($0.col(14426))) }
}
.onChange(of: vm.sort) { _, new in Task { await vm.applySort(new) } }
```

Bottom toolbar: "Run", "Load more", page indicator, total rows.

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

47 unit tests at present (`xcodebuild -only-testing:AutoscreenerTests test`). Coverage:

- `JWTTests` — payload base64url decode, `isExpiring` window
- `LoginServiceTests` — request body + headers, three response envelopes (trusted-device, new-device, flat), `expired_at` parsing, MFA outcome detection, 401 → `invalidCredentials`, refresh bearer attach
- `DeviceVerificationServiceTests` — request shapes for all four MFA endpoints, channel/target parsing from `supporting_data.otp`, `next_challenge` detection, error mapping (invalid OTP, challenge expired)
- `APIClientAuthInterceptorTests` — bearer attach, 401-then-refresh-then-retry, refresh-failure wipes tokens, **pre-flight refresh fires within the 60s window**, dead refresh wipes Keychain
- `SettingsViewModelTests` — happy sign-in, invalid creds surface, sign-out toggle, **multi-step MFA flow chains email → phone → completes**, invalid OTP stays in verification phase, expired challenge bounces back
- `ScreenerServiceWireFormatTests` — exact double-encoded `filters`/`universe` strings vs the captured fixture; pagination
- `ScreenerServiceParseTests` — three response envelope shapes + values-array / id-keyed metric layouts + missing-values tolerance
- `ScreenerViewModelTests` — run, loadMore, clear-on-rerun, error mapping
- `NetworkLogRedactionTests` — every sensitive key gets `***`, case-insensitive

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

All v1 scope shipped (§1 checklist) and exercised end-to-end against the real backend:
- Sign-in works for trusted devices (token grant) and new devices (MFA flow with sequential email→phone OTPs).
- Tokens persist with their `expired_at`; `APIClient` auto-refreshes inside the 60-second window and surrenders cleanly when the refresh JWT is dead.
- Settings shows a live, redacted network log so the wire trace is visible without leaking secrets.
- Screener service is wired but `Run` still needs a real signed-in session to confirm the screener-templates response envelope.

47 unit tests passing. Next milestone in §15.

---

## 15. Next: "bandar-accumulating" screener results view

Sign-in is solved. Now use the persisted access token to actually fetch the rows that match the captured `bandar-accumulating` screener (filters: *Bandar Value > Bandar Value MA 20* over IHSG, the same template id `6676213` in `proxseer_collection (1).json`) and present them — symbol, name, the two metric values, plus enough metadata to be useful (last price + change if we can get it cheaply).

### 15.1 Endpoint sequence (per the captured flow, executed in this order)

| # | Call | Why |
|---|---|---|
| 1 | `GET /paywall/eligibility/check?company=&features=PAYWALL_FEATURE_SCREENER` | Surface "you're paywalled" instead of failing with a cryptic 4xx. Best-effort; not a hard gate. |
| 2 | `POST /paywall/counter/increment` body `{"feature":"PAYWALL_FEATURE_SCREENER","company":""}` | Quota meter. Fire-and-forget — log failures, don't block. |
| 3 | `GET /screener/templates/6676213?limit=25&type=TEMPLATE_TYPE_CUSTOM` | Loads the saved template (filters/universe/sequence) so the client doesn't have to hardcode metric IDs. We still keep the canned `ScreenerConfig` as a fallback when this fails. |
| 4 | `POST /screener/templates` with `save:"0"` + that template's filters + a `page` counter | Runs the screener. Page 1, 25 rows. "Load more" bumps `page`. |

(The current `ScreenerService.run` already implements step 4 with a hardcoded config. Steps 1–3 are new.)

### 15.2 New services / changes

- **`PaywallService`** (new) — `check(feature:)` / `increment(feature:)`. Thin, both endpoints return small JSON envelopes; treat decoding failures as "eligible / counted".
- **`ScreenerTemplateService`** (new) — `load(templateID:)` returning a `ScreenerTemplate { name, filters, universe, sequence, orderColumn, orderType }`. Replaces the hand-coded `ScreenerConfig.bandarValueAboveMA20` constants as the source of truth; constants stay as last-resort fallback.
- **`ScreenerService.run`** — accepts the loaded template. No wire-format changes.
- **`ScreenerRow` enrichment** — keep `symbol`, `name`, `values[]`. The screener response very likely also carries `last_price`, `pct_change`, `volume`, `market_cap` — extend `ScreenerRow` with **optional** fields, populated when the response contains them.

### 15.3 ViewModel

`ScreenerViewModel` gains a one-shot bootstrap before the first `run`:

```swift
func startBandarAccumulating() async {
    await paywall.increment(feature: .screener)        // fire-and-forget
    if let tpl = try? await templates.load(id: "6676213") { self.config = tpl }
    await run()
}
```

`run()` already populates `rows`, `total`, `currentPage`. `loadMore()` already bumps `page`. Sort comparator extends naturally to the new optional fields.

### 15.4 UI

`ScreenerView.resultsTable` is currently hardcoded to two metric columns. Generalise:

- Render fixed leading columns: **Symbol**, **Name**, **Last** (price), **Δ%** (color-coded green/red), then one column per metric in `config.sequence`.
- "Last" and "Δ%" only render when the row has those values; otherwise skip the column to avoid empty whitespace.
- Toolbar shows the template `name` ("bandar-accumulating") plus a "Refresh" button (re-runs from page 1, increments paywall counter again).
- Empty-state copy updates: "No matches in IHSG right now" vs "Press Run".

### 15.5 Tests (new)

- `PaywallServiceTests` — request paths + bodies; tolerant of empty responses
- `ScreenerTemplateServiceTests` — parses `filters` (double-decoded), `universe`, `sequence` out of the captured fixture; returns a runnable `ScreenerConfig`
- `ScreenerViewModelTests` extension — `startBandarAccumulating` calls paywall + templates + run in order; fallback to hardcoded config when template load fails
- Response-parsing test for the new optional row fields (`last_price`, `pct_change`)

### 15.6 Open before implementation

1. **Auto-run on launch, or manual Run only?** Auto-running burns a paywall counter on every app open; manual feels safer.
2. **Show company logo per row?** `assets.stockbit.com/logos/companies/{TICKER}.png` is public, no auth — cheap win for visual scanning. Confirm before adding the `AsyncImage`.
3. **Sort persistence** — should the user's chosen sort persist across runs, or always reset to template default? Current code resets.
