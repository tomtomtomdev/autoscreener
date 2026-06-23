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
        // Force the market OPEN so the global manual-Refresh button (shown only when nothing
        // auto-fetches) stays hidden — this suite asserts the *per-screen* Refresh control is gone,
        // and pinning the clock keeps that deterministic regardless of when CI runs.
        app.launchArguments += ["-UITestFixtures", "-UITestMarketOpen"]
        app.launch()
        return app
    }

    private func sidebarItem(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let button = app.buttons[label]
        return button.exists ? button : app.staticTexts[label].firstMatch
    }

    /// On this runner the default-selected detail column doesn't always surface to XCUITest until the
    /// sidebar selection changes. Bounce off another item and back to force the Recommendations detail
    /// to realize.
    private func landOnRecommendations(_ app: XCUIApplication) {
        let markets = sidebarItem(app, "Markets")
        if markets.waitForExistence(timeout: 15) { markets.click() }
        let recommendations = sidebarItem(app, "Recommendations")
        if recommendations.waitForExistence(timeout: 10) { recommendations.click() }
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

        // Screen 1 — the default landing is the unified Recommendations screen. The global status
        // indicator lives in the shared title bar.
        landOnRecommendations(app)
        XCTAssertTrue(element(app, "RecommendationsView").waitForExistence(timeout: 15),
                      "Recommendations screen should render")
        XCTAssertTrue(element(app, "globalfetchstatus").waitForExistence(timeout: 10),
                      "The global fetch-status indicator should show on Recommendations")

        // The per-screen Refresh control is gone — the status bar is the single fetch surface now.
        XCTAssertFalse(app.buttons["Refresh"].exists,
                       "The per-screen Refresh button should have been removed")

        // Screen 2 — Paper Trading (the Watchlist is now a section of screen 1, not its own tab). The
        // same single indicator persists across the shared NavigationStack on a different screen.
        let paperTrading = sidebarItem(app, "RAPaTS (Regime-Aware)")
        XCTAssertTrue(paperTrading.waitForExistence(timeout: 10), "RAPaTS sidebar item should appear")
        paperTrading.click()

        XCTAssertTrue(element(app, "PaperTradingView").waitForExistence(timeout: 10),
                      "Paper Trading screen should render")
        XCTAssertTrue(element(app, "globalfetchstatus").waitForExistence(timeout: 10),
                      "The global fetch-status indicator should also show on Paper Trading")
        XCTAssertFalse(app.buttons["Refresh"].exists,
                       "Paper Trading should not expose a per-screen Refresh button")
    }
}
