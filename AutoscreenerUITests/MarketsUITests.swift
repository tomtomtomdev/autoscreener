import XCTest
#if canImport(AppKit)
import AppKit
#endif

/// Drives the sidebar → Markets flow against canned, offline fixtures
/// (`-UITestFixtures`), verifying the new Commodities + Currencies price sections
/// render. Under fixtures the rows are fed by `StubCommodityPriceService`, so the
/// formatted price ("100") and a signed % change are deterministic — no auth,
/// network, or Keychain involved.
final class MarketsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchWithFixtures() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestFixtures"]
        app.launch()
        return app
    }

    /// Sidebar rows surface as buttons in some builds and plain static texts in
    /// others — return whichever exists for the given label.
    private func sidebarItem(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let button = app.buttons[label]
        return button.exists ? button : app.staticTexts[label].firstMatch
    }

    @MainActor
    func testMarketsShowsCommodityAndCurrencyPrices() throws {
        // macOS gives each display its own Space; with multiple displays attached,
        // XCUITest can't snapshot a window that lands on a Space other than the
        // runner's (it sees only the menu bar → windows == 0). Skip on multi-display
        // dev machines — this still runs on single-display / CI. Mirrors
        // `StockDetailUITests`.
        #if canImport(AppKit)
        try XCTSkipIf(NSScreen.screens.count > 1,
                      "XCUITest can't drive windows across separate Spaces on a multi-display setup")
        #endif

        let app = launchWithFixtures()

        // Navigate the sidebar to Markets (the screener is selected by default).
        let markets = sidebarItem(app, "Markets")
        XCTAssertTrue(markets.waitForExistence(timeout: 15), "Markets sidebar item should appear")
        markets.click()

        // The two new sections render.
        XCTAssertTrue(app.staticTexts["Commodities"].waitForExistence(timeout: 5),
                      "Commodities section header should appear in Markets")
        XCTAssertTrue(app.staticTexts["Currencies"].waitForExistence(timeout: 5),
                      "Currencies section header should appear in Markets")

        // A commodity row shows its symbol and the stubbed price snapshot.
        XCTAssertTrue(app.staticTexts["OIL"].waitForExistence(timeout: 5),
                      "OIL commodity row should be listed")
        XCTAssertTrue(app.staticTexts["100"].firstMatch.waitForExistence(timeout: 5),
                      "Stubbed formatted price should render on a priced row")

        // USD/IDR is present under Currencies.
        XCTAssertTrue(app.staticTexts["USDIDR"].waitForExistence(timeout: 5),
                      "USDIDR currency row should be listed")
    }
}
