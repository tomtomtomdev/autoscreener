# Autoscreener

Native macOS client for running [Stockbit](https://stockbit.com) screeners against the Indonesia Stock Exchange (IDX), built 100% on Apple SDKs — SwiftUI + URLSession + Keychain, no third-party dependencies.

> Personal / educational project. Talks to Stockbit's public mobile endpoints using a real Stockbit account. Not affiliated with PT Stockbit Sekuritas Digital.

---

## What it does

1. Sign in with your Stockbit credentials in **Settings** (`⌘,`).
2. Tokens (access + refresh) are stored in the macOS Keychain; the password is never persisted.
3. The auth layer transparently refreshes the access token on 401 and retries the original request.
4. Pick or build a screener (e.g. *Bandar Value > Bandar Value MA 20*), hit **Run**.
5. Results render in a sortable, paginated `Table`.

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

### Package as DMG

```bash
./scripts/build_dmg.sh
# → build/Autoscreener.dmg
```

The script archives with Release config, exports a `.app`, and wraps it in a drag-to-Applications DMG. See the script header for code-signing / notarisation flags.

---

## Project layout

```
Autoscreener/
├── App/            # @main entry + scenes
├── Core/
│   ├── Networking/ # APIClient, AuthInterceptor, DTOs
│   ├── Auth/       # LoginService, TokenStore (Keychain), JWT
│   └── Common/     # DeviceInfo / header construction
├── Features/
│   ├── Settings/   # Sign-in form
│   └── Screener/   # Filters + Table results
└── Resources/
```

`AutoscreenerTests` covers networking, auth refresh, and screener parsing. `AutoscreenerUITests` covers the sign-in → run-screener happy path.

---

## API references

Captured wire formats live alongside the source for reproducibility:

- `proxseer_collection.json` — login + auth + websocket-key requests
- `proxseer_collection (1).json` — screener / paywall / chart requests

Hosts touched: `exodus.stockbit.com` (REST), `assets.stockbit.com` (logos), optionally `ws3.stockbit.com` / `wss-jkt.trading.stockbit.com` (real-time, out of scope for v1).

---

## Security notes

- Password is held in `@State` only, cleared on submit.
- Tokens use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Network calls are HTTPS-only (App Sandbox + outgoing-network entitlement).
- No telemetry, no analytics, no third-party SDKs.

---

## Status

Early WIP. Project skeleton is in place; feature implementation is the next milestone. Tracked in [SPEC.md §13](SPEC.md#13-status).
