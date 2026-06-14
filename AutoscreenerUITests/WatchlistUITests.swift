import XCTest
#if canImport(AppKit)
import AppKit
#endif

/// Drives the composite Watchlist against canned, offline fixtures (`-UITestFixtures`).
/// The app lands on the Watchlist by default; its rows come entirely from the shared
/// `ScreenerStore` cache, seeded once by the sweep coordinator over the stub services.
/// Verifies cache-backed rendering and that the liquidity **veto excludes** a stock
/// missing from the intraday-liquidity gate (GOTO) rather than tagging it.
final class WatchlistUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchWithFixtures() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestFixtures"]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func sidebarItem(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let button = app.buttons[label]
        return button.exists ? button : app.staticTexts[label].firstMatch
    }

    @MainActor
    func testWatchlistRendersFromCacheAndExcludesVetoedStock() throws {
        // macOS gives each display its own Space; XCUITest can't snapshot a window on
        // another Space (windows == 0). Skip on multi-display dev machines; runs on CI.
        #if canImport(AppKit)
        try XCTSkipIf(NSScreen.screens.count > 1,
                      "XCUITest can't drive windows across separate Spaces on a multi-display setup")
        #endif

        let app = launchWithFixtures()

        // The unified Recommendations inbox is the default landing now — navigate to the Watchlist,
        // which renders from the seeded cache.
        let watchlist = sidebarItem(app, "Watchlist")
        XCTAssertTrue(watchlist.waitForExistence(timeout: 15), "Watchlist sidebar item should appear")
        watchlist.click()

        XCTAssertTrue(element(app, "WatchlistView").waitForExistence(timeout: 15),
                      "Watchlist screen should render")

        // BBCA and TLKM appear in every screener (including both liquidity gates) → survive.
        XCTAssertTrue(element(app, "watchlist.stockcode-BBCA").waitForExistence(timeout: 10),
                      "A fully-liquid stock should appear in the composite")
        XCTAssertTrue(element(app, "watchlist.stockcode-TLKM").waitForExistence(timeout: 5),
                      "A fully-liquid stock should appear in the composite")

        // Each surviving row shows its screener-provenance icon strip (right of the score). BBCA/TLKM
        // match every screener under fixtures, so their signal strips are non-empty → the cell exists.
        XCTAssertTrue(element(app, "watchlist.screeners-BBCA").waitForExistence(timeout: 5),
                      "The screener-icon strip should render for a matched stock")
        XCTAssertTrue(element(app, "watchlist.screeners-TLKM").exists,
                      "The screener-icon strip should render for a matched stock")

        // GOTO is absent from the intraday-liquidity veto gate → excluded entirely.
        XCTAssertFalse(element(app, "watchlist.stockcode-GOTO").exists,
                       "A stock failing a liquidity veto gate must be excluded, not shown")
    }
}
