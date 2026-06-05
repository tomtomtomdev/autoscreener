import Foundation
import Testing
@testable import Autoscreener

// MARK: - Endpoint wire format (verified paths from the Proxseer capture)

@Suite struct GovernanceEndpointTests {
    private func query(_ ep: Endpoint) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ep.query.compactMap { item in item.value.map { (item.name, $0) } })
    }

    @Test func majorHolderEndpoint() {
        let ep = GovernanceService.makeMajorHolderEndpoint(symbol: "TPIA", period: .oneYear, limit: 30, page: 1)
        #expect(ep.method == .get)
        #expect(ep.path == "insider/company/majorholder")
        #expect(query(ep)["symbols"] == "TPIA")
        #expect(query(ep)["period_type"] == "PERIOD_TYPE_1_YEAR")
        #expect(query(ep)["limit"] == "30")
        #expect(query(ep)["page"] == "1")
    }

    @Test func compositionAndCorpActionAndSubsidiaryPaths() {
        #expect(GovernanceService.makeCompositionEndpoint(symbol: "TPIA").path == "insider/shareholding/composition/companies/TPIA")
        #expect(GovernanceService.makeCorpActionEndpoint(symbol: "TPIA").path == "corpaction/TPIA")
        #expect(GovernanceService.makeSubsidiaryEndpoint(symbol: "TPIA").path == "emitten-metadata/subsidiary/TPIA")
    }

    @Test func ownershipEndpoint() {
        let ep = GovernanceService.makeOwnershipEndpoint(insiderID: "15283", symbol: "TPIA", page: 2)
        #expect(ep.path == "insider/majorholder/ownership")
        #expect(query(ep)["insider"] == "15283")
        #expect(query(ep)["symbol"] == "TPIA")
        #expect(query(ep)["page"] == "2")
    }
}

// MARK: - Throttled sequential orchestration

@Suite struct GovernanceServiceThrottleTests {
    actor Recorder {
        private(set) var delays: [UInt64] = []
        func record(_ ns: UInt64) { delays.append(ns) }
    }

    private func makeService(_ recorder: Recorder, responses: Int) -> (GovernanceService, StubSession) {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        let stubs = Array(repeating: StubSession.Stub(status: 200, body: Data("{}".utf8)), count: responses)
        let session = StubSession(stubs)
        let client = APIClient(session: session, tokens: store)
        let service = GovernanceService(apiClient: client, sleeper: { await recorder.record($0) })
        return (service, session)
    }

    @Test func reportIssuesSectionsSequentiallyWithThrottleGaps() async throws {
        let recorder = Recorder()
        // 4 base sections; cross-holdings skip (no holders parse out of "{}").
        let (service, session) = makeService(recorder, responses: 4)

        _ = try await service.report(symbol: "TPIA", period: .oneYear)

        let delays = await recorder.delays
        #expect(session.received.count == 4)   // one request per section, issued in order
        #expect(delays.count == 3)             // first request free, the next three throttled
        #expect(delays.allSatisfy { $0 >= 1_000_000_000 && $0 <= 1_500_000_000 })
    }

    @Test func emptyBodiesYieldEmptyReportWithoutMissingSections() async throws {
        // A 200 with an empty object isn't a *failure* — defensive parse → empty section.
        let recorder = Recorder()
        let (service, _) = makeService(recorder, responses: 4)

        let data = try await service.report(symbol: "TPIA", period: .oneYear)

        #expect(data.majorHolders.isEmpty)
        #expect(data.corpActions.isEmpty)
        #expect(data.missingSections.isEmpty)  // parsed-but-empty ≠ missing
    }
}

// MARK: - Parsing against the Phase 0 fixtures

@Suite struct GovernanceParseTests {
    @Test func parsesMajorHoldersWithBadgesAndSignedChange() {
        let holders = GovernanceService.parseMajorHolders(GovernanceFixtures.majorHolder)
        #expect(holders.count == 2)
        let director = holders[0]
        #expect(director.insiderID == "15283")
        #expect(director.isInsider)                       // DIREKTUR badge
        #expect(director.ownershipPercent == 2.0)
        #expect(director.changeInOwnershipPct == -1.5)    // signed "-1.50"
        #expect(holders[1].isInsider == false)            // no role badge
    }

    @Test func parsesCompositionBreakdown() {
        let composition = GovernanceService.parseComposition(GovernanceFixtures.composition)
        #expect(composition?.holders.count == 4)
        #expect(composition?.holders.first?.label == "SCG CHEMICALS PUBLIC COMPANY")
        #expect(composition?.holders.first?.percent == 30.57)
        // The same data flowing through the rule → thin float (free = 100 − 57.13).
        #expect(GovernanceRules.freeFloat(composition).map { abs($0 - 42.87) < 1e-9 } == true)
    }

    @Test func parsesCorpActionsTypesAndNestedExDate() {
        let actions = GovernanceService.parseCorpActions(GovernanceFixtures.corpAction)
        #expect(actions.count == 4)
        let rights = actions.first { $0.type == .rightsIssue }
        #expect(rights != nil)                                  // "rightissue" mapped
        #expect(rights?.date != nil)                            // pulled rightissue_exdate
        #expect(actions.contains { $0.type == .cashDividend })  // "dividend"
        #expect(actions.contains { $0.type == .split })         // "stocksplit"
        #expect(actions.contains { $0.type == .other })         // "rups"
    }

    @Test func parsesSubsidiaries() {
        let subs = GovernanceService.parseSubsidiaries(GovernanceFixtures.subsidiary)
        #expect(subs.count == 2)
        #expect(subs.first?.name == "Aster Chemicals and Energy Pte. Ltd.")
        #expect(subs.first?.ownershipPercent == 100.0)
    }

    @Test func parsesCrossHoldingsExcludingTheQueriedSymbol() {
        let cross = GovernanceService.parseCrossHoldings(GovernanceFixtures.ownership, holderName: "fallback", excluding: "TPIA")
        #expect(cross.count == 1)                       // TPIA itself filtered out
        #expect(cross.first?.symbol == "BRPT")
        #expect(cross.first?.holderName == "DIRECTOR A") // taken from data.insider_name
        #expect(cross.first?.ownershipPercent == 3.5)
    }
}
