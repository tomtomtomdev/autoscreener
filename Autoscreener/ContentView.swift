import SwiftUI

struct ContentView: View {
    @State private var auth = AppDependencies.shared.authState

    var body: some View {
        Group {
            switch auth.phase {
            case .unknown:
                ProgressView("Checking session…")
                    .frame(minWidth: 480, minHeight: 320)
            case .signedIn:
                MainSidebarView()
            case .signedOut:
                signInPrompt
            }
        }
        .task {
            // Skip the Keychain probe when the app is launched under any test runner
            // (xctest host or UI-test SUT) — otherwise each fresh Debug build re-prompts
            // for ACL trust on the stockbit-tokens item and stalls the runner.
            guard !ProcessInfo.processInfo.isRunningTests else { return }
            if auth.phase == .unknown {
                auth.phase = await AppDependencies.shared.tokens.load() != nil ? .signedIn : .signedOut
            }
            // Once signed in, start the continuous market-hours screener sweep that
            // fills the shared cache. Idempotent — safe to call on every appearance.
            if auth.phase == .signedIn {
                AppDependencies.shared.screenerSweepCoordinator.start()
            }
        }
    }

    private var signInPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.horizontal")
                .imageScale(.large)
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Sign in to Stockbit").font(.title2)
            Text("Open Settings (⌘,) and enter your Stockbit credentials to run screeners.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            SettingsLink {
                Text("Open Settings…")
            }
            .keyboardShortcut(",", modifiers: [.command])
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 320)
    }
}

#Preview { ContentView() }
