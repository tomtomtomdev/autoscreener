# Autoscreener — Spec

macOS-native client for running Stockbit screeners against the IDX market. Logs in to `exodus.stockbit.com`, manages access/refresh tokens transparently, lets the user describe a screen, fires it, and renders the results in a sortable table.

Target: macOS 15.0+ (Sequoia). Stack: SwiftUI, `@Observable`, `URLSession` async/await, Keychain, no third-party deps.

---

## 1. Scope (v1)

- [ ] **Settings → Account**: username + password `TextField`s, "Sign in" button. Credentials never persisted in plaintext; tokens stored in Keychain.
- [ ] **Auth pipeline**: `POST /login/v6/username` → store access + refresh JWTs → auto-refresh on 401 via `POST /login/refresh` → silent retry of the originating request.
- [ ] **Screener run**: minimal filter UI (or canned "Bandar Value > Bandar Value MA 20" preset) → `POST /screener/templates` with `save:"0"` → render rows.
- [ ] **Results table**: SwiftUI `Table` with sortable columns (symbol, name, + selected metrics).
- [ ] **Pagination**: increment `page` in the request body when scrolling past the loaded set.
- [ ] **Build DMG**: `scripts/build_dmg.sh` produces a notarisable `Autoscreener.dmg`.

Out of scope for v1: charting, real-time WebSocket, saving custom templates, multi-account, paywall enforcement (we hit `paywall/eligibility/check` and surface the result, but don't gate UI).

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
│   └── AutoscreenerApp.swift              // @main, root WindowGroup + SettingsScene
├── Core/
│   ├── Networking/
│   │   ├── APIClient.swift                // generic send<T: Decodable>(Endpoint) async throws -> T
│   │   ├── Endpoint.swift                 // URL, method, body, requiresAuth flag
│   │   ├── AuthInterceptor.swift          // attaches Bearer, handles 401 → refresh → retry once
│   │   └── DTO/                           // Codable structs for login & screener responses
│   ├── Auth/
│   │   ├── LoginService.swift             // login(user, pass) / refresh()
│   │   ├── TokenStore.swift               // Keychain (kSecClassGenericPassword) get/set/clear
│   │   └── JWT.swift                      // decode `exp` to detect expiry pre-emptively
│   └── Common/
│       └── DeviceInfo.swift               // x-devicetype / x-appversion / UA assembly
├── Features/
│   ├── Settings/
│   │   ├── SettingsView.swift             // TextField username + SecureField password + Sign In
│   │   └── SettingsViewModel.swift
│   └── Screener/
│       ├── ScreenerView.swift             // controls + Table
│       ├── ScreenerViewModel.swift        // run(), loadMore(), sort
│       ├── ScreenerService.swift          // wraps POST /screener/templates
│       └── Models/Row.swift               // symbol, name, columns[Double]
└── Resources/
    └── Assets.xcassets
```

---

## 3. Auth flow

### 3.1 Login
1. User enters username + password in **Settings**.
2. `LoginService.login(user:password:)` →
   ```
   POST https://exodus.stockbit.com/login/v6/username
   Content-Type: application/json
   Body: {"user":"…","password":"…","player_id":"<persisted-uuid>"}
   ```
   + standard headers (see §5).
3. Decode response → extract `access_token`, `refresh_token` (field names to be confirmed at first integration — the proxy capture has no response body).
4. `TokenStore.save(access, refresh)` → Keychain, account `"stockbit-tokens"`.
5. Clear password from memory; never persist.

### 3.2 Refresh-on-401
`AuthInterceptor` wraps every authenticated request:

```
send(req):
  attach Bearer access_token
  resp = URLSession.data(req)
  if resp.status == 401 and not already-retried:
    if not refreshing:
      refreshing = true
      newPair = LoginService.refresh(refreshToken)   // POST /login/refresh
      TokenStore.save(newPair)
      refreshing = false
    else:
      await refreshing-finished
    return send(req, retried=true)
  return resp
```

- Serialise refresh attempts with an `actor` so concurrent 401s collapse to one refresh call.
- If refresh itself returns 401 → wipe tokens, post `.userSignedOut` notification, surface "Please sign in again" in UI.

### 3.3 Pre-emptive refresh
Decode `exp` from access JWT on app launch; if `exp - now < 5min`, refresh before first request. Skips a guaranteed 401.

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

```swift
Form {
  Section("Account") {
    TextField("Username or email", text: $vm.username)
      .textContentType(.username)
      .autocorrectionDisabled()
    SecureField("Password", text: $vm.password)
      .textContentType(.password)

    Button(vm.isSignedIn ? "Sign out" : "Sign in") { Task { await vm.submit() } }
      .disabled(vm.isSubmitting || vm.username.isEmpty || vm.password.isEmpty)

    if let error = vm.error {
      Text(error).foregroundStyle(.red).font(.callout)
    }
    if vm.isSignedIn {
      Text("Signed in as \(vm.displayName ?? vm.username)").font(.callout).foregroundStyle(.secondary)
    }
  }
}
.formStyle(.grouped)
.frame(width: 420)
```

Lives under `Settings { SettingsView() }` scene so it's reachable via `⌘,` on macOS.

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

- `LoginError.invalidCredentials` (400/401 on login) → red inline text in Settings.
- `LoginError.network` → "Couldn't reach Stockbit. Check your connection."
- `ScreenerError.unauthorized` after refresh attempt → bounce to Settings.
- `ScreenerError.paywall` (if `paywall/eligibility/check` says ineligible) → banner above table.

---

## 10. Testing

- `LoginServiceTests`: stub `URLProtocol`, assert request shape (headers, body), parse fixture responses, refresh-on-401 retry path. Use `tdd-kent-beck` + `xunit-test-patterns`.
- `TokenStoreTests`: real Keychain in a test-specific service name; teardown wipes.
- `ScreenerServiceTests`: verify double-encoded `filters`/`universe` exactly match captured wire format (compare against fixture from `proxseer_collection.json`).
- `ScreenerViewModelTests`: pagination, sort, error mapping.
- UI smoke via `xcui-automation-testing`: launch → Settings → fill creds → Sign in → run preset → first row appears within 10s.

---

## 11. Build & distribution

- Scheme: `Autoscreener` (Release config) → `.app` in DerivedData.
- `scripts/build_dmg.sh` (see repo) — archives, exports a Developer ID–signed `.app`, wraps it into `Autoscreener.dmg` with a drag-to-Applications layout. Notarisation step is a separate manual `xcrun notarytool submit` once Apple Developer creds are in env.

---

## 12. Open questions

1. **Response shape** of `/login/v6/username` and `/screener/templates` — capture not included. Will be confirmed on first live call; lock the `Codable` models after.
2. **Server tolerance for non-iOS headers**: spec currently spoofs iOS. If we want a real Mac UA we need to test.
3. **Metric catalog**: `/screener/preset` likely returns the full metric ID → label map. Need to call it once and ship as bundled JSON or refresh on launch.
4. **Paywall**: is `screener/templates` blocked server-side for non-eligible users, or only metered? Decides whether we need to honour `eligibility/check`.

---

## 13. Status

Project skeleton in place (Xcode project, `AutoscreenerApp.swift`, `ContentView.swift`). No feature code yet. Next steps: scaffold the file layout in §2, then implement Auth pipeline (§3), then Screener (§4 + §7).
