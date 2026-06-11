import XCTest
#if canImport(AppKit)
import AppKit
#endif

/// Drives the sidebar → Today's Picks flow against canned, offline fixtures (`-UITestFixtures`).
/// Under fixtures the picks are deterministic — two ranked recommendations (an industrial, WIFI, on
/// the Graham path and a bank, BBNI, on the justified-P/B path) seeded in `UITestFixtures
/// .recommendations`, surfaced through `AppDependencies.todaysPicks` without any engine fan-out,
/// auth, network, or Keychain. Verifies the screen renders the ranked cards with their suggested
/// weights and the expandable rationale.
final class TodaysPicksUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchWithFixtures() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestFixtures"]
        app.launch()
        return app
    }

    private func sidebarItem(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let button = app.buttons[label]
        return button.exists ? button : app.staticTexts[label].firstMatch
    }

    /// Query an element by accessibility identifier, type-agnostically (SwiftUI surfaces these as
    /// different element kinds across macOS builds).
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    func testTodaysPicksShowsRankedRecommendations() throws {
        // Today's Picks is hidden from the sidebar for now (the feature code remains).
        // Skip until it's resurfaced. See the "hide Today's Picks" change.
        try XCTSkipIf(true, "Today's Picks is hidden from the sidebar for now")

        // macOS gives each display its own Space; with multiple displays attached, XCUITest can't
        // snapshot a window on another Space (windows == 0). Skip on multi-display dev machines —
        // still runs on single-display / CI. Mirrors `RegimeUITests` / `MarketsUITests`.
        #if canImport(AppKit)
        try XCTSkipIf(NSScreen.screens.count > 1,
                      "XCUITest can't drive windows across separate Spaces on a multi-display setup")
        #endif

        let app = launchWithFixtures()

        let picks = sidebarItem(app, "Today's Picks")
        XCTAssertTrue(picks.waitForExistence(timeout: 15), "Today's Picks sidebar item should appear")
        picks.click()

        // The screen renders and reports the deterministic fixture count.
        XCTAssertTrue(element(app, "TodaysPicksView").waitForExistence(timeout: 10),
                      "Today's Picks screen should render")
        let summary = element(app, "todayspicks.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "Pick count summary should render")
        XCTAssertEqual(summary.label, "2 picks", "Fixture seeds exactly two ranked picks")

        // Both ranked picks render as cards — the industrial (WIFI) and the bank (BBNI).
        XCTAssertTrue(element(app, "todayspicks.row.WIFI").waitForExistence(timeout: 5),
                      "Top (industrial) pick card should render")
        XCTAssertTrue(element(app, "todayspicks.row.BBNI").waitForExistence(timeout: 5),
                      "Second (bank) pick card should render")

        // The per-pick rationale (the engine's audit trail) is available behind its disclosure.
        XCTAssertTrue(element(app, "todayspicks.why.WIFI").waitForExistence(timeout: 5),
                      "Pick rationale disclosure should render")
    }
}
