import SwiftUI

nonisolated enum SidebarItem: Hashable, CaseIterable, Identifiable {
    case bandarAccumulating
    case bandarAboveMA20
    case appSettings

    var id: Self { self }
    var title: String {
        switch self {
        case .bandarAccumulating: return "Bandar Accumulating"
        case .bandarAboveMA20:    return "Bandar Above MA20"
        case .appSettings:        return "Settings"
        }
    }
    var systemImage: String {
        switch self {
        case .bandarAccumulating: return "chart.bar.doc.horizontal"
        case .bandarAboveMA20:    return "chart.line.uptrend.xyaxis"
        case .appSettings:        return "gearshape"
        }
    }
    var templateID: String? {
        switch self {
        case .bandarAccumulating: return "6676213"
        case .bandarAboveMA20:    return "6676217"
        case .appSettings:        return nil
        }
    }
}

struct MainSidebarView: View {
    @State private var selection: SidebarItem? = .bandarAccumulating

    // Hold one ViewModel per screener so switching tabs preserves their loaded rows
    // and doesn't fire a fresh paywall counter on every back-and-forth.
    @State private var bandarAccumulatingVM: ScreenerViewModel
    @State private var bandarAboveMA20VM: ScreenerViewModel

    init() {
        let deps = AppDependencies.shared
        _bandarAccumulatingVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            templateID: "6676213"
        ))
        _bandarAboveMA20VM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            templateID: "6676217"
        ))
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Screeners") {
                    ForEach([SidebarItem.bandarAccumulating, .bandarAboveMA20]) { item in
                        Label(item.title, systemImage: item.systemImage).tag(item)
                    }
                }
                Section {
                    Label(SidebarItem.appSettings.title,
                          systemImage: SidebarItem.appSettings.systemImage)
                        .tag(SidebarItem.appSettings)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .bandarAccumulating:
            ScreenerView(vm: bandarAccumulatingVM, title: SidebarItem.bandarAccumulating.title)
                .id(SidebarItem.bandarAccumulating)
        case .bandarAboveMA20:
            ScreenerView(vm: bandarAboveMA20VM, title: SidebarItem.bandarAboveMA20.title)
                .id(SidebarItem.bandarAboveMA20)
        case .appSettings:
            AppSettingsView()
                .id(SidebarItem.appSettings)
        case .none:
            ContentUnavailableView("Pick a screener", systemImage: "sidebar.left")
        }
    }
}
