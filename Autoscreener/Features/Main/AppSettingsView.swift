import SwiftUI

struct AppSettingsView: View {
    @State private var isLoggingOut = false

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Signed in", value: "Stockbit")
                Button(role: .destructive) {
                    Task { await logout() }
                } label: {
                    HStack {
                        if isLoggingOut {
                            ProgressView().controlSize(.small)
                            Text("Logging out…")
                        } else {
                            Label("Log out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
                .disabled(isLoggingOut)
            }

            Section("About") {
                LabeledContent("Backend", value: "exodus.stockbit.com")
                LabeledContent("App", value: "Autoscreener (Debug)")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420)
        .padding()
    }

    @MainActor
    private func logout() async {
        isLoggingOut = true
        defer { isLoggingOut = false }
        let deps = AppDependencies.shared
        await deps.loginService.signOut()
        deps.authState.setSignedOut()
        // ContentView is observing authState and will swap back to the sign-in prompt
        // automatically; no further navigation work needed.
    }
}

#Preview { AppSettingsView() }
