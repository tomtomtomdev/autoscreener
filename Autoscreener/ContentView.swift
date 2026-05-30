import SwiftUI

struct ContentView: View {
    @State private var isSignedIn: Bool = AppDependencies.shared.isSignedInSync

    var body: some View {
        Group {
            if isSignedIn {
                ScreenerView()
            } else {
                signInPrompt
            }
        }
        .task {
            isSignedIn = await AppDependencies.shared.tokens.load() != nil
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
            Button("Open Settings…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            Button("I've signed in — recheck") {
                Task { isSignedIn = await AppDependencies.shared.tokens.load() != nil }
            }
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 320)
    }
}

#Preview { ContentView() }
