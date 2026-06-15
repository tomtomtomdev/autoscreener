import Foundation

nonisolated enum PaywallFeature: String, Sendable {
    case screener = "PAYWALL_FEATURE_SCREENER"
    case foreignDomestic = "PAYWALL_FEATURE_FOREIGN_DOMESTIC"
}

nonisolated struct PaywallEligibility: Sendable, Equatable {
    let eligible: Bool
    let message: String?
}

nonisolated protocol PaywallServicing: Sendable {
    func check(_ feature: PaywallFeature) async -> PaywallEligibility
    func increment(_ feature: PaywallFeature) async
}

nonisolated final class PaywallService: PaywallServicing {
    private let apiClient: APIClient
    init(apiClient: APIClient) { self.apiClient = apiClient }

    func check(_ feature: PaywallFeature) async -> PaywallEligibility {
        let endpoint = Endpoint(
            method: .get,
            path: "paywall/eligibility/check",
            query: [URLQueryItem(name: "company", value: ""),
                    URLQueryItem(name: "features", value: feature.rawValue)]
        )
        guard let data = try? await apiClient.sendRaw(endpoint) else {
            return PaywallEligibility(eligible: true, message: nil)
        }
        return Self.parseEligibility(data)
    }

    func increment(_ feature: PaywallFeature) async {
        let body = try? JSONSerialization.data(
            withJSONObject: ["feature": feature.rawValue, "company": ""]
        )
        let endpoint = Endpoint(method: .post, path: "paywall/counter/increment", body: body)
        _ = try? await apiClient.sendRaw(endpoint)
    }

    static func parseEligibility(_ data: Data) -> PaywallEligibility {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return PaywallEligibility(eligible: true, message: nil)
        }
        let payload = (json["data"] as? [String: Any]) ?? json
        // Common shapes: {is_eligible:bool, message?}, {eligible:bool}, {status:"ELIGIBLE"|"BLOCKED"}
        if let b = payload["is_eligible"] as? Bool ?? payload["eligible"] as? Bool {
            return PaywallEligibility(eligible: b, message: payload["message"] as? String)
        }
        if let status = payload["status"] as? String {
            return PaywallEligibility(eligible: status.uppercased() != "BLOCKED",
                                      message: payload["message"] as? String)
        }
        return PaywallEligibility(eligible: true, message: nil)
    }
}
