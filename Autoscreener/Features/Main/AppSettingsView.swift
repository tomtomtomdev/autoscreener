import SwiftUI

struct AppSettingsView: View {
    @State private var isLoggingOut = false
    @State private var isRefreshing = false
    @Bindable private var preferences = AppDependencies.shared.schedulePreferences
    @Bindable private var scheduler = AppDependencies.shared.scheduler

    var body: some View {
        Form {
            Section("Refresh schedule") {
                Picker("Cadence", selection: $preferences.schedule) {
                    ForEach(ScreenerSchedule.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                LabeledContent("Last refresh", value: relativeText(scheduler.lastFireDate))
                LabeledContent("Next refresh",
                               value: scheduler.nextFireDate.map(absoluteText)
                                      ?? (preferences.schedule == .onDemand ? "Manual only" : "—"))

                Button {
                    Task { await refreshNow() }
                } label: {
                    HStack {
                        if isRefreshing {
                            ProgressView().controlSize(.small)
                            Text("Refreshing…")
                        } else {
                            Label("Refresh now", systemImage: "arrow.clockwise")
                        }
                    }
                }
                .disabled(isRefreshing)

                Text(scheduleFootnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
        .frame(minWidth: 480)
        .padding()
    }

    private var scheduleFootnote: String {
        switch preferences.schedule {
        case .onDemand:
            return "Tabs refresh on first reveal and stay put until you tap Refresh."
        case .quarterHourly, .hourly:
            return "Auto-refresh only fires while Autoscreener is running. Snapshots are written to ~/Library/Application Support/Autoscreener."
        case .dailyOpen, .dailyClose:
            return "Daily refresh anchored to Asia/Jakarta wall-clock (WIB / UTC+7). Auto-refresh only fires while Autoscreener is running."
        }
    }

    @MainActor
    private func refreshNow() async {
        isRefreshing = true
        defer { isRefreshing = false }
        // Settings doesn't hold the WatchlistViewModel; the sidebar does. Forward
        // the request via NotificationCenter — observed by MainSidebarView.
        NotificationCenter.default.post(name: .autoscreenerRefreshNow, object: nil)
    }

    @MainActor
    private func logout() async {
        isLoggingOut = true
        defer { isLoggingOut = false }
        let deps = AppDependencies.shared
        deps.scheduler.stop()
        await deps.loginService.signOut()
        deps.authState.setSignedOut()
    }

    private func relativeText(_ date: Date?) -> String {
        guard let date else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func absoluteText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: "Asia/Jakarta") ?? .current
        let time = formatter.string(from: date)
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "MMM d"
        dayFormatter.timeZone = formatter.timeZone
        return "\(dayFormatter.string(from: date)) \(time) WIB"
    }
}

extension Notification.Name {
    static let autoscreenerRefreshNow = Notification.Name("autoscreener.refreshNow")
}

#Preview { AppSettingsView() }
