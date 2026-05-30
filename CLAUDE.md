# Autoscreener — Skill Router

iOS/macOS Swift project. Route to the right skill based on what the user is asking, then apply it.

## Routing table

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

## Combination rules

- **New feature, test-first** → `tdd-kent-beck` (drive cycle) + `xunit-test-patterns` (test design) + the architecture skill matching the layer.
- **Refactoring existing code without tests** → `legacy-code` first (get a safety net), then `refactoring-fowler`.
- **Reviewing a PR / existing code** → `clean-code` for local quality + `clean-architecture` for structural concerns + `xunit-test-patterns` if tests are touched.
- **SwiftUI screen work** → `swiftui-architecture` for structure; if it's macOS-specific (windows, menu bar, AppKit interop), also `macos-development`.
- **UI test work** → `xcui-automation-testing` + `xunit-test-patterns` for test design hygiene.

## Defaults for this project

- Swift / SwiftUI / XCTest. Prefer protocol-based DI for testability.
- When in doubt between MVVM and UDF for new SwiftUI features, consult `swiftui-architecture` (UDF + lightweight clean boundaries is the recommended default).
- Always run/check the matching skill *before* writing tests or giving code-quality advice — don't answer from priors.
