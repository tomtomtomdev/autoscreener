import XCTest
#if canImport(AppKit)
import AppKit
#endif

/// Verifies the market-state-aware manual Refresh control (SPEC §15): a global `globalrefresh`
/// title-bar button that appears only when nothing is auto-refreshing. Driven against canned,
/// offline fixtures with the clock pinned (`-UITestMarketClosed` / `-UITestMarketOpen`) so the
/// market-state-dependent visibility is deterministic regardless of when CI runs.
final class ManualRefreshUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ extraArgs: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestFixtures"] + extraArgs
        app.launch()
        return app
    }

    private func sidebarItem(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let button = app.buttons[label]
        return button.exists ? button : app.staticTexts[label].firstMatch
    }

    private func landOnRecommendations(_ app: XCUIApplication) {
        let markets = sidebarItem(app, "Markets")
        if markets.waitForExistence(timeout: 15) { markets.click() }
        let recommendations = sidebarItem(app, "Recommendations")
        if recommendations.waitForExistence(timeout: 10) { recommendations.click() }
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    func testRefreshButtonShowsWhenMarketClosed() throws {
        #if canImport(AppKit)
        try XCTSkipIf(NSScreen.screens.count > 1,
                      "XCUITest can't drive windows across separate Spaces on a multi-display setup")
        #endif

        let app = launch(["-UITestMarketClosed"])
        landOnRecommendations(app)

        XCTAssertTrue(element(app, "RecommendationsView").waitForExistence(timeout: 15),
                      "Recommendations screen should render")
        // Market closed → nothing auto-fetches → the manual Refresh control is available.
        XCTAssertTrue(element(app, "globalrefresh").waitForExistence(timeout: 10),
                      "Manual Refresh should appear when the market is closed")
    }

    @MainActor
    func testRefreshButtonHiddenWhenMarketOpenAndAutoFetchOn() throws {
        #if canImport(AppKit)
        try XCTSkipIf(NSScreen.screens.count > 1,
                      "XCUITest can't drive windows across separate Spaces on a multi-display setup")
        #endif

        let app = launch(["-UITestMarketOpen"])
        landOnRecommendations(app)

        XCTAssertTrue(element(app, "globalfetchstatus").waitForExistence(timeout: 15),
                      "The global status indicator should render")
        // Open + continuous auto-fetch (the default) → the sweep keeps data fresh, so no manual button.
        XCTAssertFalse(element(app, "globalrefresh").exists,
                       "Manual Refresh should be hidden during normal open-hours auto-fetch")
    }
}
