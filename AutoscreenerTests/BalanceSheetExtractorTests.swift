import Foundation
import Testing
@testable import Autoscreener

// Phase 1.3 (§8/§11): the industrial balance-sheet extractor. keystats is snapshot-only and
// fundachart doesn't chart these, so the three per-year items the engine consumes — `Aset Lancar`
// (currentAssets), `Liabilitas Jangka Pendek` (currentLiabilities), `Piutang Usaha` (receivables) —
// come from the display-string tree (`findata-view/v2/financials`, report_type=2 balance sheet,
// statement_type=2 annual), parsed with `DisplayNumber.parseScaledDecimal` ("8,688 B" → 8.688e12).
//
// Fixture is trimmed verbatim from the live WIFI capture (2026-06-06). It preserves the structural
// trap that makes this fiddly: each subtotal exists TWICE under the same stripped name — once as an
// empty bold section *header* (`<b>Aset Lancar</b>` with no values, wrapping the detail rows) and
// once as the valued bold *subtotal* leaf (`<B>Aset Lancar</B>` with the figures). The extractor
// must read the valued node, never the empty header. (Real values: Aset Lancar 8,688/586 B,
// Liabilitas Jangka Pendek 3,981/584 B, Piutang Usaha 223/136 B for FY2025/FY2024.)

private let wifiBalanceSheet = Data(#"""
{
  "message": "Successfully retrieved company financial",
  "data": {
    "default_currency": "IDR",
    "data_tables": {
      "periods": ["12M 2025", "12M 2024"],
      "accounts": [
        {"id":1,"level":1,"name":"<b>Aset</b>","values":[],"accounts":[
          {"id":2,"level":2,"name":"<b>Aset Lancar</b>","values":[],"accounts":[
            {"id":3,"level":3,"name":"Kas Dan Setara Kas","values":["6,165 B","18 B"],"accounts":[]},
            {"id":4,"level":3,"name":"Piutang Usaha","values":[],"accounts":[
              {"id":5,"level":4,"name":"Pihak Berelasi","values":["-","-"],"accounts":[]},
              {"id":6,"level":4,"name":"Pihak Ketiga","values":["223 B","136 B"],"accounts":[]},
              {"id":7,"level":4,"name":"<B>Piutang Usaha</B>","values":["223 B","136 B"],"accounts":[]}
            ]},
            {"id":8,"level":3,"name":"Persediaan","values":["966 B","-"],"accounts":[]},
            {"id":9,"level":3,"name":"<B>Aset Lancar</B>","values":["8,688 B","586 B"],"accounts":[]}
          ]},
          {"id":10,"level":2,"name":"<B>Aset</B>","values":["15,170 B","2,907 B"],"accounts":[]}
        ]},
        {"id":20,"level":1,"name":"<b>Liabilitas Dan Ekuitas</b>","values":[],"accounts":[
          {"id":21,"level":2,"name":"<b>Liabilitas</b>","values":[],"accounts":[
            {"id":22,"level":3,"name":"<b>Liabilitas Jangka Pendek</b>","values":[],"accounts":[
              {"id":23,"level":4,"name":"Utang Bank Jangka Pendek","values":["1,352 B","-"],"accounts":[]},
              {"id":24,"level":4,"name":"<B>Liabilitas Jangka Pendek</B>","values":["3,981 B","584 B"],"accounts":[]}
            ]},
            {"id":25,"level":3,"name":"<b>Liabilitas Jangka Panjang</b>","values":[],"accounts":[
              {"id":26,"level":4,"name":"<B>Liabilitas Jangka Panjang</B>","values":["2,671 B","1,354 B"],"accounts":[]}
            ]}
          ]}
        ]}
      ]
    }
  }
}
"""#.utf8)

private func wifiStatement() throws -> FinancialStatement {
    try FinancialStatementService.parse(wifiBalanceSheet)
}

// MARK: - Per-year extraction

@Suite struct BalanceSheetExtractorTests {

    @Test func extractsTheThreeSubtotalsForTheLatestYear() throws {
        let items = SelectionFundamentals.balanceSheetItems(from: try wifiStatement())
        let y2025 = try #require(items[2025])
        #expect(y2025.currentAssets == Decimal(8_688_000_000_000))      // "8,688 B"
        #expect(y2025.currentLiabilities == Decimal(3_981_000_000_000)) // "3,981 B"
        #expect(y2025.receivables == Decimal(223_000_000_000))          // "223 B"
    }

    @Test func mapsEachPeriodColumnToItsFiscalYear() throws {
        // "12M 2024" → 2024, with values from the second column.
        let items = SelectionFundamentals.balanceSheetItems(from: try wifiStatement())
        let y2024 = try #require(items[2024])
        #expect(y2024.currentAssets == Decimal(586_000_000_000))
        #expect(y2024.currentLiabilities == Decimal(584_000_000_000))
        #expect(y2024.receivables == Decimal(136_000_000_000))
        #expect(Set(items.keys) == [2024, 2025])
    }

    @Test func readsTheValuedSubtotalNotTheEmptySectionHeader() throws {
        // Both the bold header `<b>Piutang Usaha</b>` (no values) and the bold subtotal
        // `<B>Piutang Usaha</B>` (223 B) strip to the same name. Picking the header would yield 0;
        // a non-zero result proves the valued node was chosen — and that the sibling detail rows
        // ("Pihak Ketiga") are not mistaken for the subtotal.
        let items = SelectionFundamentals.balanceSheetItems(from: try wifiStatement())
        #expect(items[2025]?.receivables == Decimal(223_000_000_000))
        #expect(items[2025]?.receivables != 0)
    }

    @Test func leavesAbsentItemsAtZeroRatherThanFailing() throws {
        // A balance sheet missing one named subtotal (e.g. a bank with no "Aset Lancar") yields 0
        // for that field — the engine's NCAV / forensic consumers guard on > 0, so 0 = "skip".
        let noCurrentAssets = Data(#"""
        {"data":{"default_currency":"IDR","data_tables":{"periods":["12M 2025"],"accounts":[
          {"id":1,"level":1,"name":"<B>Piutang Usaha</B>","values":["223 B"],"accounts":[]}
        ]}}}
        """#.utf8)
        let items = SelectionFundamentals.balanceSheetItems(from: try FinancialStatementService.parse(noCurrentAssets))
        #expect(items[2025]?.currentAssets == 0)
        #expect(items[2025]?.currentLiabilities == 0)
        #expect(items[2025]?.receivables == Decimal(223_000_000_000))
    }
}

// MARK: - Merge onto the fundachart-derived annuals

@Suite struct BalanceSheetMergeTests {

    private func annual(year: Int) -> AnnualFinancials {
        AnnualFinancials(
            year: year, revenue: 100, netIncome: 10, operatingCashFlow: 8,
            totalAssets: 200, totalLiabilities: 80, currentAssets: 0, currentLiabilities: 0,
            shareholderEquity: 120, receivables: 0, sharesOutstanding: 0)
    }

    @Test func overlaysTheThreeFieldsByYearAndPreservesEverythingElse() throws {
        let merged = SelectionFundamentals.merging([annual(year: 2024), annual(year: 2025)],
                                                   balanceSheet: try wifiStatement())
        let y2025 = try #require(merged.first { $0.year == 2025 })
        #expect(y2025.currentAssets == Decimal(8_688_000_000_000))
        #expect(y2025.currentLiabilities == Decimal(3_981_000_000_000))
        #expect(y2025.receivables == Decimal(223_000_000_000))
        // Fundachart-sourced fields are untouched by the overlay.
        #expect(y2025.revenue == 100)
        #expect(y2025.totalLiabilities == 80)
        #expect(y2025.shareholderEquity == 120)
    }

    @Test func leavesYearsWithNoBalanceSheetColumnUnchanged() throws {
        // 2023 has no column in the (2-year) balance sheet → its tree fields stay 0.
        let merged = SelectionFundamentals.merging([annual(year: 2023), annual(year: 2025)],
                                                   balanceSheet: try wifiStatement())
        let y2023 = try #require(merged.first { $0.year == 2023 })
        #expect(y2023.currentAssets == 0)
        #expect(y2023.receivables == 0)
    }

    @Test func preservesInputOrderingOfTheAnnuals() throws {
        let merged = SelectionFundamentals.merging([annual(year: 2024), annual(year: 2025)],
                                                   balanceSheet: try wifiStatement())
        #expect(merged.map(\.year) == [2024, 2025])
    }
}
