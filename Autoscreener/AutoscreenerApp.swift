//
//  AutoscreenerApp.swift
//  Autoscreener
//
//  Created by tomtomtom on 5/30/26.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

@main
struct AutoscreenerApp: App {
    init() {
        // Headless live-audit hook (`-RunSelectionAudit`): runs the engine against the authenticated
        // feed, prints a report, and exits. No-op on a normal launch. See `SelectionAudit`.
        SelectionAudit.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear { Self.placeWindowForUITestsIfNeeded() }
        }
        Settings {
            SettingsView()
        }
    }

    /// Under `-UITestFixtures`, pin the main window to the primary display's Space.
    /// macOS gives each display its own Space; a window restored onto a secondary
    /// display sits on a Space the XCUITest runner can't snapshot (it would see only
    /// the menu bar — `app.windows.count == 0`). No-op outside the UI-test fixtures.
    private static func placeWindowForUITestsIfNeeded() {
        #if canImport(AppKit)
        guard ProcessInfo.processInfo.isUITestFixtures else { return }
        DispatchQueue.main.async {
            guard let screen = NSScreen.main,
                  let window = NSApp.windows.first(where: { $0.canBecomeMain }) ?? NSApp.windows.first
            else { return }
            let size = window.frame.size
            let origin = NSPoint(x: screen.frame.midX - size.width / 2,
                                 y: screen.frame.midY - size.height / 2)
            window.setFrameOrigin(origin)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        #endif
    }
}
