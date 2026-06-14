import XCTest
#if canImport(AppKit)
import AppKit
#endif

/// Drives the tap-a-stock-code → financial-detail flow end-to-end against canned,
/// offline fixtures (`-UITestFixtures`), so no auth/network/Keychain is involved.
final class StockDetailUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchWithFixtures() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestFixtures"]
        app.launch()
        return app
    }

    /// macOS segmented `Picker` options surface as radio buttons in most builds and
    /// plain buttons in others — query whichever exists.
    private func segment(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let radio = app.radioButtons[label]
        return radio.exists ? radio : app.buttons[label]
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func sidebarItem(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let button = app.buttons[label]
        return button.exists ? button : app.staticTexts[label].firstMatch
    }

    /// On this runner the default-selected detail column doesn't always surface to XCUITest until the
    /// sidebar selection changes. Bounce off another item and back to force the Recommendations detail
    /// (which now hosts the watchlist section) to realize.
    private func landOnRecommendations(_ app: XCUIApplication) {
        let markets = sidebarItem(app, "Markets")
        if markets.waitForExistence(timeout: 15) { markets.click() }
        let recommendations = sidebarItem(app, "Recommendations")
        if recommendations.waitForExistence(timeout: 10) { recommendations.click() }
    }

    /// The watchlist section sits below the recommendation cards in one scroll, so its rows aren't
    /// instantiated until scrolled into view. Scroll the merged screen until `target` appears.
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ target: XCUIElement) -> Bool {
        if target.waitForExistence(timeout: 3) { return true }
        let scroll = app.scrollViews["RecommendationsView"].exists
            ? app.scrollViews["RecommendationsView"]
            : app.scrollViews.firstMatch
        for delta in [-160.0, -160, -160, -160, -160, 160, 160, 160, 160, 160] {
            guard !target.exists else { return true }
            if scroll.exists { scroll.scroll(byDeltaX: 0, deltaY: CGFloat(delta)) }
        }
        return target.exists
    }

    @MainActor
    func testTappingStockCodeOpensFinancialDetail() throws {
        // macOS gives each display its own Space; with multiple displays attached,
        // XCUITest can't snapshot a window that lands on a Space other than the
        // runner's (it sees only the menu bar → windows == 0). Skip on multi-display
        // dev machines — this still runs on single-display / CI.
        #if canImport(AppKit)
        try XCTSkipIf(NSScreen.screens.count > 1,
                      "XCUITest can't drive windows across separate Spaces on a multi-display setup")
        #endif

        let app = launchWithFixtures()

        // The Watchlist is a section of the default Recommendations screen now — scroll down to reveal
        // its rows, whose stock codes are tappable links into the financial detail.
        landOnRecommendations(app)
        XCTAssertTrue(element(app, "RecommendationsView").waitForExistence(timeout: 15),
                      "The merged Recommendations screen should render")
        let bbca = element(app, "watchlist.stockcode-BBCA")
        XCTAssertTrue(reveal(app, bbca),
                      "BBCA stock-code link should appear in the watchlist section")
        bbca.click()

        // Detail opens on the Chart tab: its timeframe control (default 1Y) is present.
        XCTAssertTrue(segment(app, "1Y").waitForExistence(timeout: 5),
                      "Chart tab's timeframe picker should appear by default")

        // Switch to the Financials tab → Annual / Income Statement view.
        let financials = segment(app, "Financials")
        XCTAssertTrue(financials.waitForExistence(timeout: 5), "Financials tab should exist")
        financials.click()
        XCTAssertTrue(app.staticTexts["12M 2025"].waitForExistence(timeout: 5),
                      "Annual period header should appear on the pushed detail")
        XCTAssertTrue(app.staticTexts["Pendapatan"].waitForExistence(timeout: 5),
                      "Income-statement account should be shown")

        // Switch report → Balance Sheet replaces the income accounts.
        let balance = segment(app, "Balance")
        XCTAssertTrue(balance.waitForExistence(timeout: 5), "Balance segment should exist")
        balance.click()
        XCTAssertTrue(app.staticTexts["Aset"].waitForExistence(timeout: 5),
                      "Balance-sheet account should appear after switching report")

        // Switch period basis → Quarterly column headers replace the annual ones.
        let quarterly = segment(app, "Quarterly")
        XCTAssertTrue(quarterly.waitForExistence(timeout: 5), "Quarterly segment should exist")
        quarterly.click()
        XCTAssertTrue(app.staticTexts["Q1 2026"].waitForExistence(timeout: 5),
                      "Quarterly period header should appear after switching basis")
    }
}
