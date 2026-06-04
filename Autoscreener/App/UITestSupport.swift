import Foundation

extension ProcessInfo {
    /// True when launched by the XCUITest suite with canned, offline data. Lets the
    /// app render the signed-in screener + stock-detail flow deterministically —
    /// no Keychain, no auth, no network. Distinct from `-UITesting`, which freezes
    /// the app on the "Checking session…" splash.
    var isUITestFixtures: Bool { arguments.contains("-UITestFixtures") }
}

// MARK: - Canned services used only under -UITestFixtures

nonisolated struct StubPaywallService: PaywallServicing {
    func check(_ feature: PaywallFeature) async -> PaywallEligibility {
        PaywallEligibility(eligible: true, message: nil)
    }
    func increment(_ feature: PaywallFeature) async {}
}

/// No-op snapshot store so the fixture run shows the canned template rows rather
/// than any stale snapshot persisted by a previous real session.
nonisolated struct StubSnapshotStore: ScreenerSnapshotStoring {
    func loadScreener(templateID: String) async -> ScreenerSnapshot? { nil }
    func saveScreener(_ snapshot: ScreenerSnapshot) async {}
    func loadWatchlist() async -> WatchlistSnapshot? { nil }
    func saveWatchlist(_ snapshot: WatchlistSnapshot) async {}
    var persistenceEnabled: Bool { get async { false } }
}

nonisolated struct StubScreenerTemplateService: ScreenerTemplateServicing {
    func load(templateID: String) async throws -> ScreenerInitialResult {
        ScreenerInitialResult(
            config: ScreenerConfig(),
            page: ScreenerPage(rows: UITestFixtures.screenerRows, total: UITestFixtures.screenerRows.count, page: 1))
    }
}

nonisolated struct StubScreenerService: ScreenerServicing {
    func run(_ config: ScreenerConfig, page: Int) async throws -> ScreenerPage {
        // Page 1 arrives via the template service; signal "no more pages".
        ScreenerPage(rows: [], total: UITestFixtures.screenerRows.count, page: page)
    }
}

nonisolated struct StubFinancialStatementService: FinancialStatementServicing {
    func load(symbol: String,
              report: FinancialReportType,
              basis: FinancialPeriodBasis) async throws -> FinancialStatement {
        UITestFixtures.statement(report: report, basis: basis)
    }
}

enum UITestFixtures {
    static let screenerRows: [ScreenerRow] = [
        ScreenerRow(symbol: "BBCA", name: "Bank Central Asia Tbk.", values: [9_876.0, 8_000.0], lastPrice: nil, pctChange: nil),
        ScreenerRow(symbol: "TLKM", name: "Telkom Indonesia Tbk.", values: [4_321.0, 3_900.0], lastPrice: nil, pctChange: nil),
        ScreenerRow(symbol: "GOTO", name: "GoTo Gojek Tokopedia Tbk.", values: [1_234.0, 1_000.0], lastPrice: nil, pctChange: nil),
    ]

    static func statement(report: FinancialReportType, basis: FinancialPeriodBasis) -> FinancialStatement {
        let periods = basis == .annual ? ["12M 2025", "12M 2024"] : ["Q1 2026", "Q4 2025"]
        let accounts: [FinancialAccount]
        switch report {
        case .income:
            accounts = [
                leaf("0", 127, "Pendapatan", ["115,672 B", "28,298 B"], emphasized: true),
                leaf("1", 131, "Beban Pokok Penjualan", ["(116,372 B)", "(25,807 B)"]),
                leaf("2", 134, "Laba Kotor", ["(700 B)", "2,491 B"], emphasized: true),
            ]
        case .balanceSheet:
            accounts = [
                leaf("0", 1, "Aset", ["206,036 B", "91,507 B"], emphasized: true),
                leaf("1", 41, "Liabilitas Dan Ekuitas", ["206,036 B", "91,507 B"], emphasized: true),
            ]
        case .cashFlow:
            accounts = [
                leaf("0", 200, "Arus Kas Dari Aktivitas Operasi", ["12,345 B", "6,789 B"], emphasized: true),
                leaf("1", 210, "Arus Kas Dari Aktivitas Investasi", ["(3,210 B)", "(1,500 B)"]),
            ]
        }
        return FinancialStatement(currency: "IDR", periods: periods, accounts: accounts)
    }

    private static func leaf(_ id: String, _ accountID: Int, _ name: String, _ values: [String], emphasized: Bool = false) -> FinancialAccount {
        FinancialAccount(id: id, accountID: accountID, name: name, level: 1,
                         values: values, isEmphasized: emphasized, defaultExpanded: false, children: [])
    }
}
