import Foundation

// Headless Tier-A "live audit" entry point — the documented-but-missing hook to run the real
// `StockSelectionEngine` against the AUTHENTICATED Stockbit feed (INTEGRATION.md / the gate-strictness
// plan's "truly-LIVE audit" follow-up). It is gated behind the `-RunSelectionAudit` launch argument so
// it NEVER affects a normal launch, the xctest host, or the `-UITestFixtures` UI runner.
//
// When requested it: (1) confirms a Keychain token, (2) ranks a small curated universe with the live
// buy engine (`AppDependencies.makeSelectionEngine`), (3) reviews the live paper book with Gate-5
// (`reviewPositions`), prints a structured report to stdout, then `exit(0)`s. The per-ticker fan-out is
// throttled and hits the live API, so this is intentionally opt-in only.
//
// Run it (stdout must stay attached, so exec the binary directly — NOT via `open`):
//   .../Autoscreener.app/Contents/MacOS/Autoscreener -RunSelectionAudit
//   .../Autoscreener.app/Contents/MacOS/Autoscreener -RunSelectionAudit -SelectionAuditTickers BBCA,WIFI
@MainActor
enum SelectionAudit {

    /// True when the app was launched to run the audit (suppresses the normal GUI sweep — see ContentView).
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-RunSelectionAudit")
    }

    /// Default curated universe: one industrial witness + the three large IDX banks, so the run
    /// exercises BOTH archetypes (industrial Graham/NCAV floor + financial justified-P/B) and the
    /// recent gate-strictness fixes. Override with `-SelectionAuditTickers A,B,C`.
    static let defaultUniverse: [Ticker] = ["WIFI", "BBCA", "BBNI", "BMRI"]

    /// Kicks off the audit if `-RunSelectionAudit` is present, then exits the process. Call from the
    /// app entry point before the scene does any work.
    static func runIfRequested() {
        guard isRequested else { return }
        Task {
            await run()
            // exit() (not _exit) flushes stdio so the piped report isn't truncated.
            exit(0)
        }
    }

    // MARK: - The audit

    static func run() async {
        let deps = AppDependencies.shared
        let universe = parsedUniverse() ?? defaultUniverse

        emit("══════════════════════════════════════════════════════════════")
        emit("  Selection LIVE audit — \(ISO8601DateFormatter().string(from: Date()))")
        emit("  Config: .balanced   Universe (\(universe.count)): \(universe.joined(separator: ", "))")
        emit("══════════════════════════════════════════════════════════════")

        guard await deps.tokens.load() != nil else {
            emit("✗ NOT SIGNED IN — no Stockbit token in the Keychain. Sign in via the app first.")
            return
        }
        emit("✓ Auth: Keychain token present.\n")

        // `-SelectionAuditProbe`: skip the engine and directly exercise the price-feed endpoint across
        // date spans + symbols, printing the raw HTTP status/body — to diagnose a live 400.
        if ProcessInfo.processInfo.arguments.contains("-SelectionAuditProbe") {
            await probePriceFeed(deps, universe: universe)
            emit("\n── probe complete ──")
            return
        }

        await runBuyEngine(deps, universe: universe)
        await runPositionReview(deps)

        emit("\n── audit complete ──")
    }

    // MARK: - Price-feed probe (diagnose a live 400)

    private static func probePriceFeed(_ deps: AppDependencies, universe: [Ticker]) async {
        let sym = universe.first(where: { $0 == "BBCA" }) ?? universe.first ?? "BBCA"
        emit("PRICE-FEED VARIANT PROBE — company-price-feed/historical/summary/\(sym)")
        emit("(documents the accepted query shape — server caps `limit` at 50; >50 ⇒ 400 INVALID_PARAMETER)")
        emit("──────────────────────────────────────────────")
        let now = Date()
        let end = CompanyPriceFeedService.day(now)
        let start = CompanyPriceFeedService.day(now.addingTimeInterval(-90 * 86400))
        let path = "company-price-feed/historical/summary/\(sym)"

        func q(_ pairs: [(String, String)]) -> [URLQueryItem] { pairs.map { URLQueryItem(name: $0.0, value: $0.1) } }
        func shape(_ limit: Int) -> [URLQueryItem] {
            q([("start_date", start), ("end_date", end), ("limit", String(limit)), ("page", "1"), ("period", "HS_PERIOD_DAILY")])
        }
        // Brackets the live-verified `limit` ceiling (50 OK / 60 rejected) and pins the old broken value.
        let variants: [(String, [URLQueryItem])] = [
            ("old app shape (limit=1000)", shape(1000)),
            ("limit=60", shape(60)),
            ("limit=50 (max)", shape(50)),
            ("limit=12 (web client)", shape(12)),
        ]

        for (name, query) in variants {
            let ep = Endpoint(method: .get, path: path, query: query)
            do {
                let data = try await deps.apiClient.sendRaw(ep)
                let head = String(data: data.prefix(160), encoding: .utf8) ?? "<\(data.count) bytes>"
                emit("  ✓ \(name): OK \(data.count)B — \(head)")
            } catch let APIError.http(status, body) {
                let s = String(data: body, encoding: .utf8) ?? "<\(body.count) bytes>"
                emit("  ✗ \(name): HTTP \(status) — \(s)")
            } catch {
                emit("  ✗ \(name): ERROR \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)  // polite gap
        }
    }

    // MARK: - Buy side (Today's Picks engine)

    private static func runBuyEngine(_ deps: AppDependencies, universe: [Ticker]) async {
        emit("BUY ENGINE — ranking \(universe.count) name(s)")
        emit("──────────────────────────────────────────────")
        do {
            let collector = SkipCollector()
            let recs = try await deps.makeSelectionEngine(universe: universe, config: .balanced)
                .run { collector.add($0) }

            if recs.isEmpty {
                emit("  (no names cleared the gates — see skips below)")
            }
            for (i, r) in recs.enumerated() {
                emit(String(format: "  %d. %-6@  MoS %+.1f%%  IV %.0f  conv %.2f  weight %.1f%%  score %.3f",
                            i + 1, r.ticker as NSString, r.marginOfSafety * 100, r.intrinsicValue,
                            r.conviction, r.suggestedWeight * 100, r.compositeScore))
                for line in r.audit { emit("        · \(line)") }
            }
            reportSkips(collector.all)
        } catch {
            emit("  ✗ BUY ENGINE ERROR: \(error.localizedDescription)")
        }
        emit("")
    }

    // MARK: - Sell side (Gate-5 review of the live paper book)

    private static func runPositionReview(_ deps: AppDependencies) async {
        emit("GATE-5 POSITION REVIEW — live paper book")
        emit("──────────────────────────────────────────────")
        do {
            // The audit is a one-shot CLI with no data sweep, so it reviews LIVE (the screen's
            // `reviewPositions` reads the sweep-warmed cache, which would be cold here).
            let collector = SkipCollector()
            let decisions = try await deps.makePositionReviewer(config: .balanced)
                .review { collector.add($0) }
            if decisions.isEmpty {
                emit("  (paper book is empty — nothing to review)")
            }
            for d in decisions {
                emit("  \(d.action.rawValue.uppercased())  \(d.ticker) — \(d.reason)")
                for line in d.audit { emit("        · \(line)") }
            }
            reportSkips(collector.all)
        } catch {
            emit("  ✗ REVIEW ERROR: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private static func reportSkips(_ skips: [SkippedName]) {
        guard !skips.isEmpty else { return }
        emit("  skipped (\(skips.count)):")
        for s in skips { emit("    – \(s.ticker): \(s.reason)") }
    }

    /// `-SelectionAuditTickers BBCA,WIFI,BMRI` → `["BBCA","WIFI","BMRI"]`, else nil (use the default).
    private static func parsedUniverse() -> [Ticker]? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-SelectionAuditTickers"), i + 1 < args.count else { return nil }
        let tickers = args[i + 1]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
        return tickers.isEmpty ? nil : tickers
    }

    private static func emit(_ s: String) {
        print(s)
        fflush(stdout)  // flush so a piped/redirected capture stays live and isn't truncated
    }
}
