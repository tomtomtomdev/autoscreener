import Foundation

nonisolated enum DeviceInfo {
    static let platform = "iOS"
    static let deviceType = "iPhone 11"
    static let appVersion = "3.21.4"
    static let userAgent = "Stockbit/3.21.4 (stockbit.com.stockbit; build:40150; iOS 18.1.1) Alamofire/5.9.0"
    static let acceptLanguage = "ID"

    static var playerID: String {
        let key = "autoscreener.playerID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let new = UUID().uuidString.lowercased()
        UserDefaults.standard.set(new, forKey: key)
        return new
    }

    static var commonHeaders: [String: String] {
        [
            "accept": "*/*",
            "accept-encoding": "identity",
            "accept-language": acceptLanguage,
            "x-platform": platform,
            "x-devicetype": deviceType,
            "x-appversion": appVersion,
            "user-agent": userAgent,
        ]
    }
}
