import Foundation
import Testing
@testable import Autoscreener

// Phase 1.5 (§8 / §11 / §13-B4): the static IDX-IC sector-name → sector-index map that supplies the
// engine's `sectorIndexBars`. "Teknologi"→IDXTECHNO and "Keuangan"→IDXFINANCE are capture-verified
// (WIFI, BBCA, 2026-06-06); the 11 sector-index symbols are all confirmed present in the captures.

@Suite struct SectorIndexMapTests {
    private func info(sector: String, indexes: [String] = []) -> EmittenInfo {
        EmittenInfo(symbol: "X", name: "X", sector: sector, subSector: "", indexes: indexes)
    }

    @Test func mapsTheCaptureVerifiedSectors() {
        #expect(SelectionFundamentals.sectorIndexSymbol(forSector: "Teknologi") == "IDXTECHNO")
        #expect(SelectionFundamentals.sectorIndexSymbol(forSector: "Keuangan") == "IDXFINANCE")
    }

    @Test func coversAllElevenIdxIcSectorsWithDistinctSymbols() {
        #expect(SelectionFundamentals.sectorIndexBySector.count == 11)
        #expect(SelectionFundamentals.sectorIndexSymbols.count == 11)   // no duplicate index symbols
        for sym in SelectionFundamentals.sectorIndexSymbols { #expect(sym.hasPrefix("IDX")) }
    }

    @Test func nameLookupIsCaseAndWhitespaceInsensitive() {
        #expect(SelectionFundamentals.sectorIndexSymbol(forSector: "  teknologi ") == "IDXTECHNO")
        #expect(SelectionFundamentals.sectorIndexSymbol(forSector: "KEUANGAN") == "IDXFINANCE")
    }

    @Test func unknownSectorNameReturnsNil() {
        #expect(SelectionFundamentals.sectorIndexSymbol(forSector: "Kriptografi") == nil)
        #expect(SelectionFundamentals.sectorIndexSymbol(forSector: "") == nil)
    }

    @Test func resolvesViaNameMapFromInfo() {
        #expect(SelectionFundamentals.sectorIndexSymbol(for: info(sector: "Teknologi")) == "IDXTECHNO")
        #expect(SelectionFundamentals.sectorIndexSymbol(for: info(sector: "Keuangan")) == "IDXFINANCE")
    }

    @Test func fallsBackToIndexesMembershipWhenNameUnmapped() {
        // Spelling drift in `sector`, but the sector index is present in `indexes` (always is, verified).
        let drifted = info(sector: "Tekno-drift", indexes: ["LQ45", "IDXTECHNO", "IHSG"])
        #expect(SelectionFundamentals.sectorIndexSymbol(for: drifted) == "IDXTECHNO")
    }

    @Test func returnsNilWhenNeitherNameNorIndexesResolve() {
        let none = info(sector: "Unknown", indexes: ["LQ45", "IHSG"])
        #expect(SelectionFundamentals.sectorIndexSymbol(for: none) == nil)
    }

    @Test func nameMapTakesPrecedenceOverIndexesFallback() {
        // Deterministic: when the name maps, it wins even if `indexes` lists another sector index.
        let conflicting = info(sector: "Keuangan", indexes: ["IDXTECHNO"])
        #expect(SelectionFundamentals.sectorIndexSymbol(for: conflicting) == "IDXFINANCE")
    }
}
