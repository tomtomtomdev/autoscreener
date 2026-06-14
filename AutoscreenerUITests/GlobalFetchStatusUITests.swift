import XCTest
#if canImport(AppKit)
import AppKit
#endif

/// Verifies the chrome change locked in UI-CHROME-PLAN.md against canned, offline fixtures
/// (`-UITestFixtures`): the per-screen refresh controls are gone and a single global fetch-status
/// indicator (`globalfetchstatus`, a `.principal` title-bar item) shows on every screen instead.
final class GlobalFetchStatusUITests: XCTestCase {
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

    /// Query by accessibility identifier, type-agnostically (SwiftUI surfaces these as different
    /// element kinds across macOS builds).
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    func testGlobalStatusBarReplacesPerScreenRefresh() throws {
        // macOS gives each display its own Space; XCUITest can't snapshot a window on another Space
        // (windows == 0). Skip on multi-display dev machines; runs on single-display / CI.
        #if canImport(AppKit)
        try XCTSkipIf(NSScreen.screens.count > 1,
                      "XCUITest can't drive windows across separate Spaces on a multi-display setup")
        #endif

        let app = launchWithFixtures()

        // Screen 1 — the default Watchlist. The global status indicator lives in the shared title bar.
        XCTAssertTrue(element(app, "WatchlistView").waitForExistence(timeout: 15),
                      "Watchlist screen should render on launch")
        XCTAssertTrue(element(app, "globalfetchstatus").waitForExistence(timeout: 10),
                      "The global fetch-status indicator should show on the Watchlist")

        // The per-screen Refresh control is gone — the status bar is the single fetch surface now.
        XCTAssertFalse(app.buttons["Refresh"].exists,
                       "The per-screen Refresh button should have been removed")

        // Screen 2 — Today's Picks. The same single indicator persists across the shared NavigationStack.
        let picks = sidebarItem(app, "Today's Picks")
        XCTAssertTrue(picks.waitForExistence(timeout: 10), "Today's Picks sidebar item should appear")
        picks.click()

        XCTAssertTrue(element(app, "TodaysPicksView").waitForExistence(timeout: 10),
                      "Today's Picks screen should render")
        XCTAssertTrue(element(app, "globalfetchstatus").waitForExistence(timeout: 10),
                      "The global fetch-status indicator should also show on Today's Picks")
        XCTAssertFalse(app.buttons["Refresh"].exists,
                       "Today's Picks should no longer expose a Refresh button")
    }
}
