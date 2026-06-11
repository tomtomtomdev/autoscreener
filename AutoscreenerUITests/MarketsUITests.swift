import XCTest
#if canImport(AppKit)
import AppKit
#endif

/// Drives the sidebar → Markets flow against canned, offline fixtures
/// (`-UITestFixtures`), verifying every price section renders — the composite,
/// indices, and sectors as well as commodities + currencies. Under fixtures the
/// rows are fed by `StubCommodityPriceService`, so the formatted price ("100") and
/// a signed % change are deterministic — no auth, network, or Keychain involved.
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

    /// The pushed OHLCV chart detail, queried type-agnostically by its identifier
    /// (it surfaces as different element kinds across macOS builds).
    private func chartDetail(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "OHLCVChartView").firstMatch
    }

    @MainActor
    private func openMarkets() -> XCUIApplication {
        let app = launchWithFixtures()
        let markets = sidebarItem(app, "Markets")
        XCTAssertTrue(markets.waitForExistence(timeout: 15), "Markets sidebar item should appear")
        markets.click()
        return app
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

    /// The composite, indices, and sectors are now priced rows too — they carry a
    /// value + % change like commodities, served by the same `emitten/{symbol}/info`
    /// snapshot. Proven by the `MarketsPricedRow.<symbol>` identifier, which only the
    /// priced row sets (the old plain row had none).
    @MainActor
    func testCompositeIndexAndSectorRowsShowPriceAndChange() throws {
        #if canImport(AppKit)
        try XCTSkipIf(NSScreen.screens.count > 1,
                      "XCUITest can't drive windows across separate Spaces on a multi-display setup")
        #endif

        let app = openMarkets()

        // IHSG (composite), LQ45 (index), and IDXENERGY (sector) each render the
        // priced row, fed by the per-symbol stub quote.
        for symbol in ["IHSG", "LQ45", "IDXENERGY"] {
            let row = app.descendants(matching: .any)
                .matching(identifier: "MarketsPricedRow.\(symbol)").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5),
                          "\(symbol) should render as a priced row with a value + % change")
        }
    }

    /// Commodities and currencies have no `charts/{symbol}/daily` history, so their
    /// rows must NOT push the OHLCV chart detail. A chartable row (the composite)
    /// is the positive control proving navigation still works for everything else.
    @MainActor
    func testCommodityAndCurrencyRowsDoNotNavigateToChart() throws {
        #if canImport(AppKit)
        try XCTSkipIf(NSScreen.screens.count > 1,
                      "XCUITest can't drive windows across separate Spaces on a multi-display setup")
        #endif

        let app = openMarkets()

        // A commodity row clicks but does not push the chart detail.
        let oil = app.staticTexts["OIL"]
        XCTAssertTrue(oil.waitForExistence(timeout: 5), "OIL commodity row should be listed")
        oil.click()
        XCTAssertFalse(chartDetail(app).waitForExistence(timeout: 2),
                       "Tapping a commodity row must not push the OHLCV chart")

        // Same for the USD/IDR currency row.
        let usdidr = app.staticTexts["USDIDR"]
        XCTAssertTrue(usdidr.waitForExistence(timeout: 5), "USDIDR currency row should be listed")
        usdidr.click()
        XCTAssertFalse(chartDetail(app).waitForExistence(timeout: 2),
                       "Tapping the USD/IDR row must not push the OHLCV chart")

        // Positive control: a chartable row (the composite) still navigates.
        let composite = app.staticTexts["IHSG"]
        XCTAssertTrue(composite.waitForExistence(timeout: 5), "IHSG composite row should be listed")
        composite.click()
        XCTAssertTrue(chartDetail(app).waitForExistence(timeout: 5),
                      "Tapping a chartable row should push the OHLCV chart detail")
    }
}
