import Foundation

nonisolated protocol GovernanceServicing: Sendable {
    /// Assembles the per-stock governance facts (`idx-investing-research.md` §4, Half A):
    /// insider major-holder movements + ownership change over `period`, the shareholding
    /// composition (→ concentration & free float), corporate actions (→ dilution),
    /// subsidiaries, and the top holders' cross-holdings. Requests are issued **sequentially
    /// and throttled** (see `RequestThrottle`). A section whose endpoint fails (paywall / 404
    /// / malformed) is recorded in `GovernanceData.missingSections` rather than failing the
    /// whole report.
    func report(symbol: String, period: GovernancePeriod) async throws -> GovernanceData
}

/// Reads Stockbit's insider / corp-action endpoints for one stock and assembles
/// `GovernanceData`. The insider family (`majorholder`, `composition`, cross-holding
/// `ownership`) is paywalled (`PAYWALL_FEATURE_INSIDER`) → those sections need a Pro
/// entitlement and degrade to `missingSections` without it.
///
/// Wire shapes confirmed against the Phase 0 capture (`tools/governance-captures/`, see
/// `scripts/capture-governance.sh`). Parsers are defensive: an unexpected shape yields an
/// empty section rather than a crash.
nonisolated final class GovernanceService: GovernanceServicing {
    private let apiClient: APIClient
    private let throttleRange: ClosedRange<UInt64>
    private let sleeper: RequestThrottle.Sleeper
    /// How many of the largest holders to resolve cross-holdings for (the N+1 step).
    private let crossHoldingHolderCap: Int

    init(apiClient: APIClient,
         throttleRange: ClosedRange<UInt64> = RequestThrottle.defaultRange,
         sleeper: @escaping RequestThrottle.Sleeper = { try await Task.sleep(nanoseconds: $0) },
         crossHoldingHolderCap: Int = 3) {
        self.apiClient = apiClient
        self.throttleRange = throttleRange
        self.sleeper = sleeper
        self.crossHoldingHolderCap = crossHoldingHolderCap
    }

    func report(symbol: String, period: GovernancePeriod) async throws -> GovernanceData {
        let throttle = RequestThrottle(range: throttleRange, sleeper: sleeper)
        var data = GovernanceData(symbol: symbol, period: period)

        // Each section is best-effort: a failure records the section as missing rather than
        // sinking the report. Cancellation is the one error that propagates.
        do {
            data.majorHolders = Self.parseMajorHolders(try await raw(Self.makeMajorHolderEndpoint(symbol: symbol, period: period), throttle))
        } catch is CancellationError { throw CancellationError() } catch { data.missingSections.append("majorHolders") }

        do {
            data.composition = Self.parseComposition(try await raw(Self.makeCompositionEndpoint(symbol: symbol), throttle))
        } catch is CancellationError { throw CancellationError() } catch { data.missingSections.append("composition") }

        do {
            data.corpActions = Self.parseCorpActions(try await raw(Self.makeCorpActionEndpoint(symbol: symbol), throttle))
        } catch is CancellationError { throw CancellationError() } catch { data.missingSections.append("corpActions") }

        do {
            data.subsidiaries = Self.parseSubsidiaries(try await raw(Self.makeSubsidiaryEndpoint(symbol: symbol), throttle))
        } catch is CancellationError { throw CancellationError() } catch { data.missingSections.append("subsidiaries") }

        // Cross-holdings: one extra call per top holder (N+1), each throttled and best-effort.
        let topHolders = data.majorHolders
            .sorted { ($0.ownershipPercent ?? 0) > ($1.ownershipPercent ?? 0) }
            .prefix(crossHoldingHolderCap)
        var crossHoldings: [CrossHolding] = []
        for holder in topHolders {
            guard let insiderID = holder.insiderID else { continue }
            do {
                let body = try await raw(Self.makeOwnershipEndpoint(insiderID: insiderID, symbol: symbol), throttle)
                crossHoldings.append(contentsOf: Self.parseCrossHoldings(body, holderName: holder.name, excluding: symbol))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue   // a single holder's lookup failing shouldn't sink the report
            }
        }
        data.crossHoldings = crossHoldings
        return data
    }

    /// Throttles, then performs the request, mapping transport errors to `GovernanceError`.
    private func raw(_ endpoint: Endpoint, _ throttle: RequestThrottle) async throws -> Data {
        try await throttle.wait()
        do {
            return try await apiClient.sendRaw(endpoint)
        } catch APIError.unauthorized, APIError.notSignedIn {
            throw GovernanceError.unauthorized
        } catch APIError.http(let status, _) where status == 402 || status == 403 {
            throw GovernanceError.paywall
        } catch let err as APIError {
            throw GovernanceError.network(String(describing: err))
        }
    }

    // MARK: - Endpoints (verified paths from the Proxseer capture)

    static func makeMajorHolderEndpoint(symbol: String, period: GovernancePeriod, limit: Int = 30, page: Int = 1) -> Endpoint {
        Endpoint(method: .get, path: "insider/company/majorholder", query: [
            URLQueryItem(name: "symbols", value: symbol),
            URLQueryItem(name: "period_type", value: period.rawValue),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "page", value: String(page)),
        ])
    }

    static func makeCompositionEndpoint(symbol: String) -> Endpoint {
        Endpoint(method: .get, path: "insider/shareholding/composition/companies/\(symbol)")
    }

    static func makeCorpActionEndpoint(symbol: String) -> Endpoint {
        Endpoint(method: .get, path: "corpaction/\(symbol)")
    }

    static func makeSubsidiaryEndpoint(symbol: String) -> Endpoint {
        Endpoint(method: .get, path: "emitten-metadata/subsidiary/\(symbol)")
    }

    static func makeOwnershipEndpoint(insiderID: String, symbol: String, page: Int = 1) -> Endpoint {
        Endpoint(method: .get, path: "insider/majorholder/ownership", query: [
            URLQueryItem(name: "insider", value: insiderID),
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "page", value: String(page)),
        ])
    }

    // MARK: - Parsing (shapes confirmed against tools/governance-captures/, Phase 0)

    /// `data.movement[]`: insider/major-holder rows with role `badges`, a signed
    /// `changes.percentage` (e.g. "+0.0001" / "-1.50"), and `current.percentage`.
    static func parseMajorHolders(_ data: Data) -> [MajorHolder] {
        guard let movement = (object(data)?["data"] as? [String: Any])?["movement"] as? [[String: Any]] else { return [] }
        return movement.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            let badges = (row["badges"] as? [String]) ?? []
            return MajorHolder(
                name: name,
                isInsider: badges.contains { insiderBadges.contains($0) },
                insiderID: (row["id"] as? String) ?? row["id"].map { String(describing: $0) },
                ownershipPercent: num((row["current"] as? [String: Any])?["percentage"]),
                changeInOwnershipPct: num((row["changes"] as? [String: Any])?["percentage"]),
                pledgedPercent: nil)
        }
    }

    /// `data.periods[0].compositions[]`: `{ label, percentage: { raw: Double } }`.
    static func parseComposition(_ data: Data) -> ShareholdingComposition? {
        guard let periods = (object(data)?["data"] as? [String: Any])?["periods"] as? [[String: Any]],
              let latest = periods.first,
              let comps = latest["compositions"] as? [[String: Any]] else { return nil }
        let holders = comps.compactMap { row -> ShareholdingComposition.HolderSlice? in
            guard let label = row["label"] as? String else { return nil }
            return .init(label: label, percent: num((row["percentage"] as? [String: Any])?["raw"] ?? row["percentage"]))
        }
        return holders.isEmpty ? nil : ShareholdingComposition(holders: holders)
    }

    /// `data[]`: each `{ action_type, action_info: { <type>: { <type>_exdate, … } } }`.
    static func parseCorpActions(_ data: Data) -> [CorpAction] {
        rows(data).map { row in
            let actionType = (row["action_type"] as? String) ?? ""
            return CorpAction(
                type: mapCorpType(actionType.lowercased()),
                date: corpActionDate(row["action_info"] as? [String: Any]),
                detail: actionType.isEmpty ? nil : actionType)
        }
    }

    /// `data.subsidiaries[]`: `{ company_name, percentage: "100.00" }`.
    static func parseSubsidiaries(_ data: Data) -> [Subsidiary] {
        guard let subs = (object(data)?["data"] as? [String: Any])?["subsidiaries"] as? [[String: Any]] else { return [] }
        return subs.compactMap { row in
            (row["company_name"] as? String).map { Subsidiary(name: $0, ownershipPercent: num(row["percentage"])) }
        }
    }

    /// `data.insider_name` + `data.ownership[]`: the listed entities a holder also owns.
    /// The queried symbol is filtered out (a holder "owning" the company we asked about is
    /// not a cross-holding).
    static func parseCrossHoldings(_ data: Data, holderName: String, excluding symbol: String) -> [CrossHolding] {
        guard let root = object(data)?["data"] as? [String: Any] else { return [] }
        let name = (root["insider_name"] as? String) ?? holderName
        let owns = (root["ownership"] as? [[String: Any]]) ?? []
        return owns.compactMap { row in
            guard let sym = row["symbol"] as? String, sym.uppercased() != symbol.uppercased() else { return nil }
            let recent = (row["recent"] as? [[String: Any]])?.first
            return CrossHolding(holderName: name, symbol: sym,
                                ownershipPercent: num((recent?["current"] as? [String: Any])?["percentage"]))
        }
    }

    // MARK: - Parsing helpers

    /// Role badges that mark a holder as an insider (director / commissioner / affiliate).
    private static let insiderBadges: Set<String> = [
        "SHAREHOLDER_BADGE_DIREKTUR",
        "SHAREHOLDER_BADGE_KOMISARIS",
        "SHAREHOLDER_BADGE_AFFILIATED",
    ]

    private static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Pulls a top-level `data[]` array (the corpaction envelope), or a bare array.
    private static func rows(_ data: Data) -> [[String: Any]] {
        if let arr = object(data)?["data"] as? [[String: Any]] { return arr }
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { return arr }
        return []
    }

    private static func num(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: d
        case let i as Int: Double(i)
        case let s as String: DisplayNumber.parseDecimal(s)
        default: nil
        }
    }

    /// The ex-date out of an `action_info.<type>` block (e.g. `rightissue_exdate`).
    private static func corpActionDate(_ info: [String: Any]?) -> Date? {
        guard let sub = info?.values.first as? [String: Any] else { return nil }
        guard let exKey = sub.keys.first(where: { $0.lowercased().contains("exdate") }),
              let raw = sub[exKey] as? String else { return nil }
        return parseDate(raw)
    }

    private static func mapCorpType(_ s: String) -> CorpAction.CorpActionType {
        if s.contains("right") { return .rightsIssue }                    // "rightissue"
        if s.contains("private") || s.contains("placement") || s.contains("tanpa hmetd") { return .privatePlacement }
        if s.contains("warrant") || s.contains("waran") { return .warrant }
        if s.contains("esop") || s.contains("mesop") || s.contains("employee") { return .employeeStock }
        if s.contains("reverse") { return .reverseSplit }
        if s.contains("split") { return .split }                          // "stocksplit"
        if s.contains("bonus") { return .bonusShares }
        if s.contains("stock dividend") || s.contains("dividen saham") { return .stockDividend }
        if s.contains("dividend") || s.contains("dividen") { return .cashDividend }
        return .other                                                     // "rups" etc.
    }

    private static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(s.prefix(10)))
    }
}
