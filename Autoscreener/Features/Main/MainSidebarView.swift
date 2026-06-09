import SwiftUI

nonisolated enum SidebarItem: Hashable, CaseIterable, Identifiable {
    case todaysPicks
    case bandarAccumulating
    case bandarAboveMA20
    case bandarShiftToday
    case accumDistPositive
    case foreignFlow1M
    case foreignFlow6M
    case foreignFlow3M
    case foreignBuyStreak
    case freshForeignBuy
    case freqSpike
    case volumeSpike
    case above50MA
    case above200MA
    case earningsYield
    case pbvBelow2
    case roeQuality
    case fcfPositive
    case manageableDebt
    case liquidityFloor
    case intradayLiquidity
    case regime
    case markets
    case watchlist
    case appSettings

    var id: Self { self }
    var title: String {
        switch self {
        case .todaysPicks:        return "Today's Picks"
        case .bandarAccumulating: return "Bandar Accumulating"
        case .bandarAboveMA20:    return "Bandar Above MA20"
        case .bandarShiftToday:   return "Bandar Shift Today"
        case .accumDistPositive:  return "Accum/Dist Positive"
        case .foreignFlow1M:      return "1M Net Foreign Flow"
        case .foreignFlow6M:      return "6M Net Foreign Flow"
        case .foreignFlow3M:      return "3M Net Foreign Flow"
        case .foreignBuyStreak:   return "Foreign Buy Streak ≥5"
        case .freshForeignBuy:    return "Fresh Foreign Buy"
        case .freqSpike:          return "Frequency Spike"
        case .volumeSpike:        return "Volume Spike"
        case .above50MA:          return "Above 50MA"
        case .above200MA:         return "Above 200MA"
        case .earningsYield:      return "Earnings Yield ≥8%"
        case .pbvBelow2:          return "PBV ≤2"
        case .roeQuality:         return "ROE ≥12%"
        case .fcfPositive:        return "Positive FCF"
        case .manageableDebt:     return "DER <1.5"
        case .liquidityFloor:     return "Liquidity Floor"
        case .intradayLiquidity:  return "Intraday Liquidity"
        case .regime:             return "Market Regime"
        case .markets:            return "Markets"
        case .watchlist:          return "Watchlist"
        case .appSettings:        return "Settings"
        }
    }
    var systemImage: String {
        switch self {
        case .todaysPicks:        return "list.star"
        case .bandarAccumulating: return "chart.bar.doc.horizontal"
        case .bandarAboveMA20:    return "chart.line.uptrend.xyaxis"
        case .bandarShiftToday:   return "arrow.left.arrow.right.circle"
        case .accumDistPositive:  return "arrow.up.circle"
        case .foreignFlow1M:      return "globe.asia.australia"
        case .foreignFlow6M:      return "globe.europe.africa"
        case .foreignFlow3M:      return "globe.americas"
        case .foreignBuyStreak:   return "flame.fill"
        case .freshForeignBuy:    return "sparkles"
        case .freqSpike:          return "waveform.path.ecg"
        case .volumeSpike:        return "chart.bar.fill"
        case .above50MA:          return "chart.xyaxis.line"
        case .above200MA:         return "chart.line.uptrend.xyaxis.circle"
        case .earningsYield:      return "percent"
        case .pbvBelow2:          return "tag"
        case .roeQuality:         return "checkmark.seal"
        case .fcfPositive:        return "dollarsign.circle"
        case .manageableDebt:     return "scalemass"
        case .liquidityFloor:     return "drop.fill"
        case .intradayLiquidity:  return "bolt.fill"
        case .regime:             return "gauge.with.dots.needle.bottom.50percent"
        case .markets:            return "chart.bar.xaxis"
        case .watchlist:          return "star.circle.fill"
        case .appSettings:        return "gearshape"
        }
    }
    var templateID: String? {
        switch self {
        case .todaysPicks:        return nil
        case .bandarAccumulating: return "6676213"
        case .bandarAboveMA20:    return "6676217"
        case .bandarShiftToday:   return "6676221"
        case .accumDistPositive:  return "6676223"
        case .foreignFlow1M:      return "6676225"
        case .foreignFlow6M:      return "6676228"
        case .foreignFlow3M:      return "6676231"
        case .foreignBuyStreak:   return "6676235"
        case .freshForeignBuy:    return "6676238"
        case .freqSpike:          return "6676260"
        case .volumeSpike:        return "6676263"
        case .above50MA:          return "6676264"
        case .above200MA:         return "6676268"
        case .earningsYield:      return "6676273"
        case .pbvBelow2:          return "6676280"
        case .roeQuality:         return "6676288"
        case .fcfPositive:        return "6676291"
        case .manageableDebt:     return "6676292"
        case .liquidityFloor:     return "6676314"
        case .intradayLiquidity:  return "6676320"
        case .regime:             return nil
        case .markets:            return nil
        case .watchlist:          return nil
        case .appSettings:        return nil
        }
    }
}

struct MainSidebarView: View {
    @State private var selection: SidebarItem? = .todaysPicks

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
    @State private var freqSpikeVM: ScreenerViewModel
    @State private var volumeSpikeVM: ScreenerViewModel
    @State private var above50MAVM: ScreenerViewModel
    @State private var above200MAVM: ScreenerViewModel
    @State private var earningsYieldVM: ScreenerViewModel
    @State private var pbvBelow2VM: ScreenerViewModel
    @State private var roeQualityVM: ScreenerViewModel
    @State private var fcfPositiveVM: ScreenerViewModel
    @State private var manageableDebtVM: ScreenerViewModel
    @State private var liquidityFloorVM: ScreenerViewModel
    @State private var intradayLiquidityVM: ScreenerViewModel
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
        _foreignFlow6MVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            templateID: "6676228"
        ))
        _foreignFlow3MVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            templateID: "6676231"
        ))
        _foreignBuyStreakVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            templateID: "6676235"
        ))
        _freshForeignBuyVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            templateID: "6676238"
        ))
        _freqSpikeVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            templateID: "6676260"
        ))
        _volumeSpikeVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            templateID: "6676263"
        ))
        _above50MAVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            templateID: "6676264"
        ))
        _above200MAVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            templateID: "6676268"
        ))
        _earningsYieldVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            templateID: "6676273"
        ))
        _pbvBelow2VM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            templateID: "6676280"
        ))
        _roeQualityVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            templateID: "6676288"
        ))
        _fcfPositiveVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            templateID: "6676291"
        ))
        _manageableDebtVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            templateID: "6676292"
        ))
        _liquidityFloorVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            templateID: "6676314"
        ))
        _intradayLiquidityVM = State(initialValue: ScreenerViewModel(
            service: deps.screenerService,
            paywall: deps.paywallService,
            templates: deps.screenerTemplateService,
            templateID: "6676320"
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
                Section("Today") {
                    Label(SidebarItem.todaysPicks.title,
                          systemImage: SidebarItem.todaysPicks.systemImage)
                        .tag(SidebarItem.todaysPicks)
                }
                Section("Screeners") {
                    ForEach([SidebarItem.bandarAccumulating, .bandarAboveMA20, .bandarShiftToday, .accumDistPositive, .foreignFlow1M, .foreignFlow6M, .foreignFlow3M, .foreignBuyStreak, .freshForeignBuy, .freqSpike, .volumeSpike, .above50MA, .above200MA, .earningsYield, .pbvBelow2, .roeQuality, .fcfPositive, .manageableDebt, .liquidityFloor, .intradayLiquidity]) { item in
                        Label(item.title, systemImage: item.systemImage).tag(item)
                    }
                }
                Section("Markets") {
                    Label(SidebarItem.regime.title,
                          systemImage: SidebarItem.regime.systemImage)
                        .tag(SidebarItem.regime)
                    Label(SidebarItem.markets.title,
                          systemImage: SidebarItem.markets.systemImage)
                        .tag(SidebarItem.markets)
                }
                Section {
                    Label(SidebarItem.watchlist.title,
                          systemImage: SidebarItem.watchlist.systemImage)
                        .tag(SidebarItem.watchlist)
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
        case .todaysPicks:
            TodaysPicksView()
                .id(SidebarItem.todaysPicks)
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
        case .freqSpike:
            ScreenerView(vm: freqSpikeVM, title: SidebarItem.freqSpike.title)
                .id(SidebarItem.freqSpike)
        case .volumeSpike:
            ScreenerView(vm: volumeSpikeVM, title: SidebarItem.volumeSpike.title)
                .id(SidebarItem.volumeSpike)
        case .above50MA:
            ScreenerView(vm: above50MAVM, title: SidebarItem.above50MA.title)
                .id(SidebarItem.above50MA)
        case .above200MA:
            ScreenerView(vm: above200MAVM, title: SidebarItem.above200MA.title)
                .id(SidebarItem.above200MA)
        case .earningsYield:
            ScreenerView(vm: earningsYieldVM, title: SidebarItem.earningsYield.title)
                .id(SidebarItem.earningsYield)
        case .pbvBelow2:
            ScreenerView(vm: pbvBelow2VM, title: SidebarItem.pbvBelow2.title)
                .id(SidebarItem.pbvBelow2)
        case .roeQuality:
            ScreenerView(vm: roeQualityVM, title: SidebarItem.roeQuality.title)
                .id(SidebarItem.roeQuality)
        case .fcfPositive:
            ScreenerView(vm: fcfPositiveVM, title: SidebarItem.fcfPositive.title)
                .id(SidebarItem.fcfPositive)
        case .manageableDebt:
            ScreenerView(vm: manageableDebtVM, title: SidebarItem.manageableDebt.title)
                .id(SidebarItem.manageableDebt)
        case .liquidityFloor:
            ScreenerView(vm: liquidityFloorVM, title: SidebarItem.liquidityFloor.title, enableSearch: true)
                .id(SidebarItem.liquidityFloor)
        case .intradayLiquidity:
            ScreenerView(vm: intradayLiquidityVM, title: SidebarItem.intradayLiquidity.title, enableSearch: true)
                .id(SidebarItem.intradayLiquidity)
        case .regime:
            RegimeView()
                .id(SidebarItem.regime)
        case .markets:
            MarketsView()
                .id(SidebarItem.markets)
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
