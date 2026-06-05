import Foundation

nonisolated protocol GovernanceServicing: Sendable {
    /// Assembles the per-stock governance facts (`idx-investing-research.md` §4, Half A):
    /// major/insider holders + ownership change over `period`, free-float composition,
    /// corporate actions (dilution), subsidiaries, and the top holders' cross-holdings.
    /// Requests are issued **sequentially and throttled** (see `RequestThrottle`). A section
    /// whose endpoint fails (paywall / 404 / malformed) is recorded in
    /// `GovernanceData.missingSections` rather than failing the whole report.
    func report(symbol: String, period: GovernancePeriod) async throws -> GovernanceData
}

/// Reads Stockbit's insider / corp-action endpoints for one stock and assembles
/// `GovernanceData`. The insider family (`majorholder`, `composition`, cross-holding
/// `ownership`) is paywalled (`PAYWALL_FEATURE_INSIDER`) → those sections need a Pro
/// entitlement and degrade to `missingSections` without it.
///
/// ⚠️ **Wire shapes are UNVERIFIED.** The Proxseer capture saved request paths only, no
/// response bodies. The `parse*` helpers below decode a *best guess* of each payload and are
/// written defensively (an unexpected shape yields an empty section, never a crash). Confirm
/// every keypath against a live capture before trusting the parsed values — the endpoint
/// builders and the throttled orchestration are the verified parts; the field mapping is not.
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

    // MARK: - Parsing  ⚠️ UNVERIFIED — confirm keypaths against a live capture

    static func parseMajorHolders(_ data: Data) -> [MajorHolder] {
        rows(data).compactMap { row in
            guard let name = (row["name"] as? String) ?? (row["shareholder_name"] as? String) else { return nil }
            let typeText = (row["type"] as? String ?? "").lowercased()
            let isInsider = (row["is_insider"] as? Bool)
                ?? ["director", "commissioner", "affiliated", "controlling"].contains { typeText.contains($0) }
            return MajorHolder(
                name: name,
                isInsider: isInsider,
                insiderID: row["insider_id"].map { String(describing: $0) },
                ownershipPercent: num(row["percentage"] ?? row["percent"] ?? row["ownership"]),
                changeInOwnershipPct: num(row["change"] ?? row["delta"] ?? row["change_percentage"]),
                pledgedPercent: num(row["pledged"] ?? row["pledged_percentage"]))
        }
    }

    static func parseComposition(_ data: Data) -> ShareholdingComposition? {
        guard let dict = object(data)?["data"] as? [String: Any] else { return nil }
        return ShareholdingComposition(
            publicFloatPercent: num(dict["public"] ?? dict["free_float"] ?? dict["public_percentage"]),
            foreignPercent: num(dict["foreign"] ?? dict["foreign_percentage"]))
    }

    static func parseCorpActions(_ data: Data) -> [CorpAction] {
        rows(data).map { row in
            let raw = ((row["type"] as? String) ?? (row["action"] as? String) ?? "").lowercased()
            return CorpAction(
                type: mapCorpType(raw),
                date: parseDate((row["date"] as? String) ?? (row["ex_date"] as? String)),
                detail: row["description"] as? String)
        }
    }

    static func parseSubsidiaries(_ data: Data) -> [Subsidiary] {
        rows(data).compactMap { row in
            (row["name"] as? String).map { Subsidiary(name: $0, ownershipPercent: num(row["percentage"] ?? row["ownership"])) }
        }
    }

    static func parseCrossHoldings(_ data: Data, holderName: String, excluding symbol: String) -> [CrossHolding] {
        rows(data).compactMap { row in
            guard let sym = row["symbol"] as? String, sym.uppercased() != symbol.uppercased() else { return nil }
            return CrossHolding(holderName: holderName, symbol: sym, ownershipPercent: num(row["percentage"] ?? row["percent"]))
        }
    }

    // MARK: - Parsing helpers

    private static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Pulls a list of row dicts from the common Stockbit envelopes:
    /// `{data:[...]}`, `{data:{results:[...]}}`, or a bare top-level array.
    private static func rows(_ data: Data) -> [[String: Any]] {
        if let root = object(data) {
            if let arr = root["data"] as? [[String: Any]] { return arr }
            if let results = (root["data"] as? [String: Any])?["results"] as? [[String: Any]] { return results }
        }
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

    private static func mapCorpType(_ s: String) -> CorpAction.CorpActionType {
        if s.contains("rights") || s.contains("hmetd") { return .rightsIssue }
        if s.contains("private placement") || s.contains("non-preempt") || s.contains("tanpa hmetd") { return .privatePlacement }
        if s.contains("warrant") || s.contains("waran") { return .warrant }
        if s.contains("esop") || s.contains("mesop") || s.contains("employee") { return .employeeStock }
        if s.contains("reverse") { return .reverseSplit }
        if s.contains("split") || s.contains("pemecahan") { return .split }
        if s.contains("bonus") { return .bonusShares }
        if s.contains("stock dividend") || s.contains("dividen saham") { return .stockDividend }
        if s.contains("dividend") || s.contains("dividen") { return .cashDividend }
        return .other
    }

    private static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }
}
