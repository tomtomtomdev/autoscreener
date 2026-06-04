import Foundation
import Testing
@testable import Autoscreener

@Suite struct FinancialStatementFlattenTests {
    // Balance-sheet shape: two top-level subtrees that BOTH reuse server id=6
    // ("Pihak Berelasi") at their leaves — exercises positional path ids.
    static let balanceSheet = Data(#"""
    {"data":{"default_currency":"IDR","data_tables":{
      "periods":["12M 2025","12M 2024"],
      "accounts":[
        {"id":1,"level":1,"name":"<b>Aset</b>","values":[],"is_default_expanded":true,"accounts":[
          {"id":2,"level":2,"name":"<b>Aset Lancar</b>","values":[],"is_default_expanded":true,"accounts":[
            {"id":4,"level":3,"name":"Piutang Usaha","values":[],"is_default_expanded":false,"accounts":[
              {"id":6,"level":4,"name":"Pihak Berelasi","values":["660 B","867 B"],"accounts":[],"is_default_expanded":false}
            ]}
          ]}
        ]},
        {"id":41,"level":1,"name":"<b>Liabilitas Dan Ekuitas</b>","values":[],"is_default_expanded":true,"accounts":[
          {"id":42,"level":2,"name":"<b>Liabilitas</b>","values":[],"is_default_expanded":false,"accounts":[
            {"id":47,"level":3,"name":"Utang Usaha","values":[],"is_default_expanded":false,"accounts":[
              {"id":6,"level":4,"name":"Pihak Berelasi","values":["60 B","22 B"],"accounts":[],"is_default_expanded":false}
            ]}
          ]}
        ]}
      ]
    }}}
    """#.utf8)

    private func statement() throws -> FinancialStatement {
        try FinancialStatementService.parse(Self.balanceSheet)
    }

    @Test func collapsedShowsOnlyTopLevel() throws {
        let rows = try statement().flattened(expanded: [])
        #expect(rows.map(\.name) == ["Aset", "Liabilitas Dan Ekuitas"])
        #expect(rows.allSatisfy { $0.depth == 0 })
        #expect(rows[0].hasChildren == true)
        #expect(rows[0].isExpanded == false)
    }

    @Test func expandingOneParentRevealsOnlyItsDirectChild() throws {
        let rows = try statement().flattened(expanded: ["0"])
        #expect(rows.map(\.name) == ["Aset", "Aset Lancar", "Liabilitas Dan Ekuitas"])
        let asetLancar = rows[1]
        #expect(asetLancar.depth == 1)
        #expect(asetLancar.isExpanded == false) // its own children stay hidden
    }

    @Test func fullExpansionAssignsDepthsAndUniquePathIDs() throws {
        let s = try statement()
        let rows = s.flattened(expanded: s.allExpandableIDs)
        // Two distinct "Pihak Berelasi" leaves survive with different ids/values.
        let pihak = rows.filter { $0.name == "Pihak Berelasi" }
        #expect(pihak.count == 2)
        #expect(Set(pihak.map(\.id)) == ["0.0.0.0", "1.0.0.0"])
        #expect(pihak.allSatisfy { $0.depth == 3 })
        #expect(pihak[0].values != pihak[1].values)
    }

    @Test func defaultExpandedIDsHonorServerHints() throws {
        // Aset, Aset Lancar, and Liabilitas Dan Ekuitas are is_default_expanded.
        #expect(try statement().defaultExpandedIDs == ["0", "0.0", "1"])
    }

    @Test func allExpandableIDsAreEveryParent() throws {
        #expect(try statement().allExpandableIDs == ["0", "0.0", "0.0.0", "1", "1.0", "1.0.0"])
    }
}
