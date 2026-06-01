import SwiftUI

nonisolated enum SidebarItem: Hashable, CaseIterable, Identifiable {
    case bandarAccumulating
    case bandarAboveMA20
    case bandarShiftToday
    case accumDistPositive
    case foreignFlow1M
    case watchlist
    case appSettings

    var id: Self { self }
    var title: String {
        switch self {
        case .bandarAccumulating: return "Bandar Accumulating"
        case .bandarAboveMA20:    return "Bandar Above MA20"
        case .bandarShiftToday:   return "Bandar Shift Today"
        case .accumDistPositive:  return "Accum/Dist Positive"
        case .foreignFlow1M:      return "1M Net Foreign Flow"
        case .watchlist:          return "Watchlist"
        case .appSettings:        return "Settings"
        }
    }
    var systemImage: String {
        switch self {
        case .bandarAccumulating: return "chart.bar.doc.horizontal"
        case .bandarAboveMA20:    return "chart.line.uptrend.xyaxis"
        case .bandarShiftToday:   return "arrow.left.arrow.right.circle"
        case .accumDistPositive:  return "arrow.up.circle"
        case .foreignFlow1M:      return "globe.asia.australia"
        case .watchlist:          return "star.circle.fill"
        case .appSettings:        return "gearshape"
        }
    }
    var templateID: String? {
        switch self {
        case .bandarAccumulating: return "6676213"
        case .bandarAboveMA20:    return "6676217"
        case .bandarShiftToday:   return "6676221"
        case .accumDistPositive:  return "6676223"
        case .foreignFlow1M:      return "6676225"
        case .watchlist:          return nil
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
    @State private var bandarShiftTodayVM: ScreenerViewModel
    @State private var accumDistPositiveVM: ScreenerViewModel
    @State private var foreignFlow1MVM: ScreenerViewModel
    @State private var watchlistVM: WatchlistViewModel

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
        _bandarShiftTodayVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            templateID: "6676221"
        ))
        _accumDistPositiveVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            templateID: "6676223"
        ))
        _foreignFlow1MVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            templateID: "6676225"
        ))
        _watchlistVM = State(initialValue: WatchlistViewModel(
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            screener: deps.screenerService
        ))
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Screeners") {
                    ForEach([SidebarItem.bandarAccumulating, .bandarAboveMA20, .bandarShiftToday, .accumDistPositive, .foreignFlow1M, .watchlist]) { item in
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
        case .bandarShiftToday:
            ScreenerView(vm: bandarShiftTodayVM, title: SidebarItem.bandarShiftToday.title)
                .id(SidebarItem.bandarShiftToday)
        case .accumDistPositive:
            ScreenerView(vm: accumDistPositiveVM, title: SidebarItem.accumDistPositive.title)
                .id(SidebarItem.accumDistPositive)
        case .foreignFlow1M:
            ScreenerView(vm: foreignFlow1MVM, title: SidebarItem.foreignFlow1M.title)
                .id(SidebarItem.foreignFlow1M)
        case .watchlist:
            WatchlistView(vm: watchlistVM, title: SidebarItem.watchlist.title)
                .id(SidebarItem.watchlist)
        case .appSettings:
            AppSettingsView()
                .id(SidebarItem.appSettings)
        case .none:
            ContentUnavailableView("Pick a screener", systemImage: "sidebar.left")
        }
    }
}
