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

    @MainActor
    func testWatchlistRendersFromCacheAndExcludesVetoedStock() throws {
        // macOS gives each display its own Space; XCUITest can't snapshot a window on
        // another Space (windows == 0). Skip on multi-display dev machines; runs on CI.
        #if canImport(AppKit)
        try XCTSkipIf(NSScreen.screens.count > 1,
                      "XCUITest can't drive windows across separate Spaces on a multi-display setup")
        #endif

        let app = launchWithFixtures()

        // The Watchlist is the default landing screen; it renders from the seeded cache.
        XCTAssertTrue(element(app, "WatchlistView").waitForExistence(timeout: 15),
                      "Watchlist screen should render on launch")

        // BBCA and TLKM appear in every screener (including both liquidity gates) → survive.
        XCTAssertTrue(element(app, "watchlist.stockcode-BBCA").waitForExistence(timeout: 10),
                      "A fully-liquid stock should appear in the composite")
        XCTAssertTrue(element(app, "watchlist.stockcode-TLKM").waitForExistence(timeout: 5),
                      "A fully-liquid stock should appear in the composite")

        // GOTO is absent from the intraday-liquidity veto gate → excluded entirely.
        XCTAssertFalse(element(app, "watchlist.stockcode-GOTO").exists,
                       "A stock failing a liquidity veto gate must be excluded, not shown")
    }
}
