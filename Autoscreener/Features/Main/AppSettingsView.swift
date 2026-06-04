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

            Section {
                Text("Data refreshes on demand — every screener tab and the Watchlist fetch live when first revealed and whenever you tap Refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480)
        .padding()
    }

    @MainActor
    private func logout() async {
        isLoggingOut = true
        defer { isLoggingOut = false }
        let deps = AppDependencies.shared
        await deps.loginService.signOut()
        deps.authState.setSignedOut()
    }
}

#Preview { AppSettingsView() }
