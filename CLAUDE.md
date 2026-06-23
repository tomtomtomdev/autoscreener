# Autoscreener — Skill Router

iOS/macOS Swift project with a built-in investing-research knowledge base. Two skill families live here: **engineering skills** (how to build the app) and **investing & finance skills** (the domain the app reasons about). Route to the right skill based on what the user is asking, then apply it.

## Engineering skills

| When the user is doing... | Invoke skill |
|---|---|
| Writing new tests, TDD, red-green-refactor, "where do I start testing this" | `tdd-kent-beck` |
| Test smells, test doubles (mock/stub/spy/fake), fixture design, brittle/flaky tests, MVVM/Combine/Core Data test design | `xunit-test-patterns` |
| Adding tests to untested code, characterization tests, breaking dependencies, seams, sprout/wrap | `legacy-code` |
| XCUITest, UI tests, XCUIElement queries, accessibility identifiers in tests, recording flows | `xcui-automation-testing` |
| Code review for readability, naming, function/class size, code smells, "is this clean" | `clean-code` |
| Applying a specific refactoring (extract function, inline, replace conditional w/ polymorphism), behavior-preserving transforms | `refactoring-fowler` |
| System/module design, SOLID, dependency rule, layering, "where does this logic go", decoupling | `clean-architecture` |
| SwiftUI app structure, MVVM vs UDF vs TCA vs VIP, @Observable/@State/@Environment, navigation, DI, scaling SwiftUI | `swiftui-architecture` |
| AppKit/SwiftUI on Mac, Xcode setup, SwiftData/Combine/Concurrency, menu bar/windows, sandboxing/notarization | `macos-development` |
| Networking with URLSession — REST calls, URLRequest, Codable decoding, up/downloads, background transfers, WebSocket, auth challenges, URLError debugging | `urlsession` |

## Bug fixes — non-negotiable workflow

Before changing any production code to fix a bug:

1. **Run the existing tests first.** Confirm the suite is green so you know what state you're starting from. If anything is already failing, surface it before touching anything else.
2. **Find the test that should have caught this bug.** If it exists, make it fail in the way the bug manifests (adjust input or assertion to reproduce). Then fix the production code so the test goes green.
3. **If no such test exists, write one.** Following Kent Beck's *Regression Test* pattern (see `tdd-kent-beck`): write the smallest possible failing test that specifies the buggy behavior — the test *is* the bug report. Confirm it fails for the right reason (red), then fix the production code, then confirm it passes (green).
4. **Only after a failing-then-passing test exists** may you commit the fix. No "I'll add the test later." The test prevents regression and proves the fix actually addresses the reported bug.

This applies to every bug fix, no matter how small. If the bug is in code that's structurally hard to test, consult `legacy-code` to introduce a seam before writing the test — don't skip the test.

## UI verification — non-negotiable workflow

To confirm a UI change actually renders/behaves, **always write or run an XCUITest** — never drive the app via the Accessibility API (`System Events` / `osascript` AX queries) or screen-capture scripts.

1. **Launch under `-UITestFixtures`.** This bypasses Keychain/auth/network and feeds the screen from the canned `Stub*Service`s in `UITestSupport.swift`, so the flow is deterministic and offline. Add a fixture + stub there if the screen needs new data.
2. **Drive it with `XCUIApplication`** — query by accessibility identifier / label, `.click()`, and assert with `waitForExistence`. Follow the existing `StockDetailUITests` / `MarketsUITests` pattern.
3. **Guard multi-display.** On a dev machine with >1 display, XCUITest can't snapshot a window that lands on another Space (it sees only the menu bar → 0 windows). Copy the `XCTSkipIf(NSScreen.screens.count > 1, …)` guard so the test passes on single-display/CI and cleanly skips otherwise.
4. **Give every assertable view an `.accessibilityIdentifier`.** UI is verified through these, not through pixel diffing or AX-tree scraping.

Rationale: accessibility-driven screenshotting is flaky on this multi-display macOS setup and proves nothing repeatable. An XCUITest is the committed, re-runnable proof.

## Explaining behavior ("why does X happen?") — non-negotiable workflow

Whenever the user asks **why** something happens — a behavior, an outcome, a bug, "why did X not Y", "why is this empty/stuck/missing" — do **not** answer from code-reading or on-disk state alone. The explanation is only trustworthy once a test confirms it.

1. **Find the test that pins the behavior.** Search the matching `*Tests.swift` for the unit/characterization test that specifies it. If one exists, it *is* the specification — name it in the answer.
2. **Run it and confirm the result.** Execute it (`xcodebuild test -project Autoscreener.xcodeproj -scheme Autoscreener -destination 'platform=macOS' -only-testing:AutoscreenerTests/<Suite>/<test>`) and quote the green/red outcome. Never claim "the test confirms this" without having run it this session.
3. **If no such test exists, write one** (Kent Beck *Regression/Characterization Test* per `tdd-kent-beck` / `legacy-code`) that reproduces the behavior, run it, and confirm — the test becomes the proof of the explanation.
4. **Only then state the "why,"** grounded in the confirmed test result, not in priors or unverified reasoning. On-disk caches/state may illustrate the live symptom, but the *test* is what proves the mechanism.

## Combination rules

- **New feature, test-first** → `tdd-kent-beck` (drive cycle) + `xunit-test-patterns` (test design) + the architecture skill matching the layer.
- **Bug fix** → `tdd-kent-beck` (Regression Test pattern) is mandatory; add `legacy-code` if the buggy code has no seam for a test.
- **Refactoring existing code without tests** → `legacy-code` first (get a safety net), then `refactoring-fowler`.
- **Reviewing a PR / existing code** → `clean-code` for local quality + `clean-architecture` for structural concerns + `xunit-test-patterns` if tests are touched.
- **SwiftUI screen work** → `swiftui-architecture` for structure; if it's macOS-specific (windows, menu bar, AppKit interop), also `macos-development`.
- **UI test work** → `xcui-automation-testing` + `xunit-test-patterns` for test design hygiene.

## Defaults for this project

- Swift / SwiftUI / XCTest. Prefer protocol-based DI for testability.
- When in doubt between MVVM and UDF for new SwiftUI features, consult `swiftui-architecture` (UDF + lightweight clean boundaries is the recommended default).
- Always run/check the matching skill *before* writing tests or giving code-quality advice — don't answer from priors.

---

# Investing & finance skills

Domain knowledge the screener encodes. Route here whenever the user analyzes a company, a stock, a market, a track record, or a credential path — not just when building the app. As with the engineering skills, consult the matching skill *before* answering from priors.

## Routing table

| When the user is doing... | Invoke skill |
|---|---|
| Value investing, margin of safety, intrinsic value, Mr. Market, defensive vs. enterprising investor, "is this stock cheap" | `intelligent-investor` |
| Reading/interpreting a balance sheet or income statement, computing ratios (current, quick, working capital, net-net, coverage, book value) à la Graham (1937) | `graham-financial-statements` |
| Qualitative growth analysis — Fisher's 15 Points, Scuttlebutt, management/R&D quality, whether a growth stock is worth holding | `common-stocks-uncommon-profits` |
| Peter Lynch story-driven analysis, six-category classification, PEG, "what's the story", ten-baggers, fast growers | `one-up-on-wall-street` |
| Buffett owner-mindset analysis — moats, owner earnings, ROE, "is this a wonderful business", long-term hold | `essays-of-warren-buffett` |
| Buffett frameworks in his own words from the Berkshire letters — owner/look-through earnings, economic goodwill, float, institutional imperative, retained-earnings test | `buffett-shareholder-letters` |
| Intrinsic valuation / DCF (FCFF, FCFE), WACC / cost of equity, terminal value, justifying or decomposing a multiple (PE, PEG, EV/EBITDA, P/B) | `damodaran-valuation` |
| Forensic earnings quality — are reported profits real and cash-backed (O'Glove), core vs. reported EPS, receivables/inventory/tax red flags | `quality-of-earnings` |
| Detecting accounting gimmicks / earnings manipulation / fraud risk in a 10-K/10-Q (Schilit) — the quality filter to run before trusting numbers in a screen | `financial-shenanigans` |
| Munger worldly wisdom — four filters, inversion, circle of competence, psychology of misjudgment / bias screen, Lollapalooza, pressure-testing a thesis | `munger-mental-models` |
| Howard Marks judgment check — second-level thinking, "where are we in the cycle", offense vs. defense, is a thesis already consensus, risk as permanent loss | `howard-marks` |
| Market-cycle / pendulum / investor-psychology assessment and contrarian positioning from *The Most Important Thing* | `most-important-thing` |
| Luck vs. skill, survivorship bias, hidden tail/black-swan risk, judging a track record or "winning streak" (Taleb) | `fooled-by-randomness` |
| Reasoning about risk & probability — odds, expected value, position sizing, regression to the mean, base rates, Bayesian updating (Bernstein) | `against-the-gods` |
| How to study for / qualify for the CFA charter — levels, topic weights, eligibility, prep providers | `cfa-prep` |
| Becoming a financial planner / advisor, the CFP credential, the four E's, planning domains, FPSB Indonesia | `cfp-prep` |
| Indonesian WMI (Wakil Manajer Investasi) license — managing funds/portfolios professionally, OJK licensing, TICMI exams | `wmi-prep` |
| Indonesian WPPE (Wakil Perantara Pedagang Efek) license — securities brokerage, working at a sekuritas firm, OJK licensing | `wppe-prep` |

## How to layer them

Stock analysis usually wants more than one skill. Treat them as stacked layers:

- **Value the business (quantitative):** `damodaran-valuation` for intrinsic/DCF; `graham-financial-statements` to read the statements; `intelligent-investor` for margin of safety.
- **Judge business & growth quality (qualitative):** `common-stocks-uncommon-profits` (Fisher), `essays-of-warren-buffett` / `buffett-shareholder-letters` (moats, owner earnings), `one-up-on-wall-street` (Lynch story + category).
- **Vet the numbers first:** run `financial-shenanigans` / `quality-of-earnings` *before* trusting reported figures fed into any value or growth screen.
- **Audit the judgment & risk (behavioral):** `munger-mental-models` for bias/decision quality, `howard-marks` / `most-important-thing` for cycle & contrarian positioning, `fooled-by-randomness` and `against-the-gods` for luck-vs-skill and probability/sizing.
- **Career/credential questions** (`cfa-prep`, `cfp-prep`, `wmi-prep`, `wppe-prep`) are standalone roadmaps — invoke singly, not as part of a stock analysis.

When several apply, lead with the layer the user asked for, then cross-check with the adjacent layers (e.g. value a stock with `damodaran-valuation`, then sanity-check the earnings with `financial-shenanigans` and the decision psychology with `munger-mental-models`).
