# Autoscreener

Native macOS client for running [Stockbit](https://stockbit.com) screeners against the Indonesia Stock Exchange (IDX), built 100% on Apple SDKs — SwiftUI + URLSession + Keychain, no third-party dependencies.

> Personal / educational project. Talks to Stockbit's public mobile endpoints using a real Stockbit account. Not affiliated with PT Stockbit Sekuritas Digital.

---

## What it does

1. Sign in with your Stockbit credentials in **Settings** (`⌘,`).
2. If the device is new, the app walks the Stockbit MFA flow inline — auto-sends the email OTP, you type the 6 digits, server demands a second OTP on WhatsApp/SMS, repeat until tokens are issued.
3. Tokens (access + refresh) live in the macOS Keychain; the password is never persisted.
4. The auth layer **pre-emptively refreshes** the access token 60 seconds before it expires (using the server's `expired_at`), and falls back to a single 401-then-refresh-retry as a backstop.
5. The sidebar lists eleven canned screener tabs — **Bandar Accumulating**, **Bandar Above MA20**, **Bandar Shift Today**, **Accum/Dist Positive**, **1M / 6M / 3M Net Foreign Flow**, **Foreign Buy Streak ≥5**, **Fresh Foreign Buy**, **Liquidity Floor**, **Intraday Liquidity** — plus a composite **Watchlist** that unions all eleven and scores each symbol by per-rule weight (mirrors `bandar-master.json`; max composite **14.0**). The last two tabs are *veto gates*: stocks missing from either are flagged red "ILLIQUID" in the Watchlist regardless of their bandar score.
6. Results render in a sortable `Table` (`No · Symbol · Name · <metric 1> · <metric 2>`; the second metric column is omitted for single-column screeners like Accum/Dist Positive and the three foreign-flow tabs). Scrolling to the last row auto-loads the next page; pagination stops when Stockbit returns an empty page, a partial page below `limit`, or `total` is reached.
7. A configurable **refresh schedule** lives in Settings (⌘,): on-demand, every 15 minutes, hourly, daily at 08:45 IDX open (Asia/Jakarta), or daily at 16:15 IDX close. Auto-refresh modes persist per-screener + watchlist snapshots to `~/Library/Application Support/Autoscreener/` so the next launch boots from disk instantly while a fresh fetch runs in the background. Every screener tab and the Watchlist also have a Refresh button in the toolbar; scheduled fan-outs reuse the same 1000–1500 ms throttle the watchlist already enforces.
8. A live **network log panel** under Settings (⌘,) shows every request and response, with sensitive values (`password`, `otp`, `*_token`, `authorization`) redacted to `***` in the display while the wire keeps the real values.

Full technical breakdown: [SPEC.md](SPEC.md).

---

## Requirements

- macOS 15.0 (Sequoia) or later
- Xcode 16+
- A Stockbit account (free tier works for paywalled features within quota)

---

## Build & run

```bash
git clone <this repo>
cd Autoscreener
open Autoscreener.xcodeproj
# pick the Autoscreener scheme, ⌘R
```

Or, from the command line:

```bash
xcodebuild -project Autoscreener.xcodeproj -scheme Autoscreener \
  -configuration Debug -destination 'platform=macOS,arch=arm64' build
```

### Tests

```bash
xcodebuild -project Autoscreener.xcodeproj -scheme Autoscreener \
  -destination 'platform=macOS,arch=arm64' -only-testing:AutoscreenerTests test
```

112 unit tests covering the auth pipeline (login, MFA, refresh, expiry), the ten-screener wire format and response parsers, the Watchlist composite (dedupe, scoring, throttled sequential fan-out, partial-failure & cancellation handling), the schedule + snapshot persistence layer (next-fire math for all five cadences, on-disk round-trip, snapshot-aware bootstrap, scheduler lifecycle), the view models, and network-log redaction.

### Package as DMG

```bash
./scripts/build_dmg.sh
# → build/Autoscreener.dmg
```

Optional env: `SIGN_IDENTITY="Developer ID Application: …"` and `NOTARY_PROFILE=AC_PASSWORD` to produce a signed + notarised DMG. See the script header.

---

## Project layout

```
Autoscreener/
├── App/                  # @main entry, AppDependencies composition root
├── Core/
│   ├── Networking/       # APIClient (actor), Endpoint, NetworkLog, LoginDTO
│   ├── Auth/             # LoginService, DeviceVerificationService, TokenStore, JWT
│   └── Common/           # DeviceInfo / shared headers + player_id
├── Features/
│   ├── Settings/         # Phase-driven sign-in / MFA / signed-in UI + log panel
│   └── Screener/         # ScreenerService, ScreenerViewModel, Table view
├── Autoscreener.entitlements   # app-sandbox + network.client
└── Assets.xcassets
```

`AutoscreenerTests` covers networking, auth refresh, MFA flow, screener parsing, and redaction. `AutoscreenerUITests` covers the launch path.

---

## API references

Captured wire formats live alongside the source for reproducibility (gitignored — they contain real credentials and JWTs):

- `proxseer_collection.json` — `intraday-liquidity` template 6676320 (`Value >= 10B`, veto gate)
- `proxseer_collection (1).json` — `liquidity-floor` template 6676314 (`Value MA 20 >= 5B`, veto gate)
- `proxseer_collection (2).json` — `foreign-flow-3m` template 6676231
- `proxseer_collection (3).json` — `foreign-buy-streak` template 6676235 (`Net Foreign Buy Streak >= 5`)
- `proxseer_collection (5).json` — `fresh-foreign-buy` template 6676238 (`Net Foreign Buy Streak > 0`)

(Earlier proxseer captures covering initial sign-in / MFA / paywall / `foreign-flow-1m` (6676225) / `foreign-flow-6m` (6676228) have been overwritten in Downloads; the wire shapes are pinned by `ScreenerServiceWireFormatTests`.)

Hosts touched: `exodus.stockbit.com` (REST), `assets.stockbit.com` (logos). Out of scope for v1: `ws3.stockbit.com` / `wss-jkt.trading.stockbit.com` (real-time WebSockets).

---

## Security notes

- Password is held in SwiftUI `@State` only, cleared on submit. Never written to disk, defaults, or memory.
- Tokens use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- App is sandboxed; entitlements grant outgoing network only (HTTPS-only by ATS default).
- The network log redacts known sensitive JSON keys in the displayed text; the underlying `URLRequest` is sent unchanged. Don't paste log output into shared channels without re-checking.
- No telemetry, no analytics, no third-party SDKs.

---

## Status

v1 + eleven screener tabs (Accumulating, Above MA20, Shift Today, Accum/Dist Positive, 1M / 6M / 3M Net Foreign Flow, Foreign Buy Streak ≥5, Fresh Foreign Buy, Liquidity Floor, Intraday Liquidity) + composite Watchlist + configurable refresh schedule with on-disk persistence are all shipped and working end-to-end against the real `exodus.stockbit.com` backend. The two liquidity tabs act as veto gates: a stock missing from either gets a red "ILLIQUID" flag in the Watchlist regardless of bandar score. Sign-in (trusted + new-device MFA), pre-flight token refresh, four-call screener bootstrap (paywall check + increment + template-with-page-1 + POST pages 2+), and infinite-scroll pagination are all in place. The Watchlist fan-out is throttled (sequential, randomised 1000–1500 ms gap) and cancellation-tolerant so a tab switch mid-bootstrap doesn't surface as a user-visible error. Scheduled refresh modes (15-min / hourly / daily IDX open / daily IDX close) write snapshots to Application Support so cold-start is instant.

**Next milestones** — see [SPEC §16](SPEC.md#16-possible-next-milestones) for the ranked menu (filter editor, saved-screeners list, last-screener persistence, company detail, real-time WebSocket, Codable migration of the remaining JSONSerialization spots).
