import SwiftUI

nonisolated enum SidebarItem: Hashable, CaseIterable, Identifiable {
    case bandarAccumulating
    case bandarAboveMA20
    case bandarShiftToday
    case accumDistPositive
    case foreignFlow1M
    case foreignFlow6M
    case foreignFlow3M
    case foreignBuyStreak
    case freshForeignBuy
    case liquidityFloor
    case intradayLiquidity
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
        case .foreignFlow6M:      return "6M Net Foreign Flow"
        case .foreignFlow3M:      return "3M Net Foreign Flow"
        case .foreignBuyStreak:   return "Foreign Buy Streak ≥5"
        case .freshForeignBuy:    return "Fresh Foreign Buy"
        case .liquidityFloor:     return "Liquidity Floor"
        case .intradayLiquidity:  return "Intraday Liquidity"
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
        case .foreignFlow6M:      return "globe.europe.africa"
        case .foreignFlow3M:      return "globe.americas"
        case .foreignBuyStreak:   return "flame.fill"
        case .freshForeignBuy:    return "sparkles"
        case .liquidityFloor:     return "drop.fill"
        case .intradayLiquidity:  return "bolt.fill"
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
        case .foreignFlow6M:      return "6676228"
        case .foreignFlow3M:      return "6676231"
        case .foreignBuyStreak:   return "6676235"
        case .freshForeignBuy:    return "6676238"
        case .liquidityFloor:     return "6676314"
        case .intradayLiquidity:  return "6676320"
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
    @State private var foreignFlow6MVM: ScreenerViewModel
    @State private var foreignFlow3MVM: ScreenerViewModel
    @State private var foreignBuyStreakVM: ScreenerViewModel
    @State private var freshForeignBuyVM: ScreenerViewModel
    @State private var liquidityFloorVM: ScreenerViewModel
    @State private var intradayLiquidityVM: ScreenerViewModel
    @State private var watchlistVM: WatchlistViewModel

    init() {
        let deps = AppDependencies.shared
        let snaps = deps.snapshotStore
        _bandarAccumulatingVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            snapshots: snaps,
            templateID: "6676213"
        ))
        _bandarAboveMA20VM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            snapshots: snaps,
            templateID: "6676217"
        ))
        _bandarShiftTodayVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            snapshots: snaps,
            templateID: "6676221"
        ))
        _accumDistPositiveVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            snapshots: snaps,
            templateID: "6676223"
        ))
        _foreignFlow1MVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            snapshots: snaps,
            templateID: "6676225"
        ))
        _foreignFlow6MVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            snapshots: snaps,
            templateID: "6676228"
        ))
        _foreignFlow3MVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            snapshots: snaps,
            templateID: "6676231"
        ))
        _foreignBuyStreakVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            snapshots: snaps,
            templateID: "6676235"
        ))
        _freshForeignBuyVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            snapshots: snaps,
            templateID: "6676238"
        ))
        _liquidityFloorVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            snapshots: snaps,
            templateID: "6676314"
        ))
        _intradayLiquidityVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            snapshots: snaps,
            templateID: "6676320"
        ))
        _watchlistVM = State(initialValue: WatchlistViewModel(
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            screener: deps.screenerService,
            snapshots: snaps
        ))
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Screeners") {
                    ForEach([SidebarItem.bandarAccumulating, .bandarAboveMA20, .bandarShiftToday, .accumDistPositive, .foreignFlow1M, .foreignFlow6M, .foreignFlow3M, .foreignBuyStreak, .freshForeignBuy, .liquidityFloor, .intradayLiquidity, .watchlist]) { item in
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
        .task { startScheduler() }
        // Restart the scheduler whenever the user changes the cadence.
        .onChange(of: AppDependencies.shared.schedulePreferences.schedule) { _, _ in
            startScheduler()
        }
        // Settings' "Refresh now" button posts this; the sidebar owns the watchlist VM.
        .onReceive(NotificationCenter.default.publisher(for: .autoscreenerRefreshNow)) { _ in
            Task { await watchlistVM.refresh() }
        }
    }

    /// Wires the global scheduler to the watchlist VM. A scheduled fire calls
    /// `watchlistVM.refresh()`, which seeds per-screener snapshots as it goes
    /// (see WatchlistViewModel for the persistence path).
    private func startScheduler() {
        let scheduler = AppDependencies.shared.scheduler
        let vm = watchlistVM
        scheduler.start(refresh: { await vm.refresh() })
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
        case .foreignFlow6M:
            ScreenerView(vm: foreignFlow6MVM, title: SidebarItem.foreignFlow6M.title)
                .id(SidebarItem.foreignFlow6M)
        case .foreignFlow3M:
            ScreenerView(vm: foreignFlow3MVM, title: SidebarItem.foreignFlow3M.title)
                .id(SidebarItem.foreignFlow3M)
        case .foreignBuyStreak:
            ScreenerView(vm: foreignBuyStreakVM, title: SidebarItem.foreignBuyStreak.title)
                .id(SidebarItem.foreignBuyStreak)
        case .freshForeignBuy:
            ScreenerView(vm: freshForeignBuyVM, title: SidebarItem.freshForeignBuy.title)
                .id(SidebarItem.freshForeignBuy)
        case .liquidityFloor:
            ScreenerView(vm: liquidityFloorVM, title: SidebarItem.liquidityFloor.title)
                .id(SidebarItem.liquidityFloor)
        case .intradayLiquidity:
            ScreenerView(vm: intradayLiquidityVM, title: SidebarItem.intradayLiquidity.title)
                .id(SidebarItem.intradayLiquidity)
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
