import Foundation
import PDFKit

/// Indonesia's bond-side flow leg — foreign (non-resident) ownership of tradable government
/// securities (SBN), the bond-market analogue of the equity foreign-flow factor. Foreign hands
/// hold a meaningful slice of Indonesian government debt, and the direction they move it is a
/// genuine smart-money tell: accumulation pulls capital into IDR duration (supporting the rupiah
/// and risk appetite), distribution is the bond-market face of capital flight.
///
/// **The vote is the month-to-date change in foreign holdings** (a rising book = risk-on, a
/// shrinking one = risk-off — the same sign as the equity foreign-flow leg). The level (in Rp
/// trillions) and the share of all tradable SBN ride along as detail qualifiers, not second votes:
/// they describe the same position the flow is moving, so scoring them too would over-count one leg
/// (the "don't double-count" discipline the CDS/CNY/breadth qualifiers also follow).
///
/// Sourced from DJPPR Kemenkeu's daily "Kepemilikan SBN" file. Its current-year data publishes
/// only as a PDF, so the reading is built from the reliable page-1 "Non Residen" row (see
/// `MacroParsing.parseSBNOwnership`) — a deliberately robust-over-fresh read that leans on the
/// early-month days and degrades to `nil` (the factor drops) on any layout anomaly.
nonisolated struct BondFlowReading: Sendable, Equatable {
    /// Latest non-resident SBN holding parsed from the file, in trillions of rupiah (e.g. `865.89`).
    let foreignHoldingsTrillions: Double
    /// Non-resident share of all tradable SBN, in percent (e.g. `12.53`), or `nil` when the
    /// percentage table was absent or implausible — the level still drives the factor.
    let foreignSharePercent: Double?
    /// Month-to-date percent change in the foreign holding over the parsed window (e.g. `-0.23`).
    /// **This is the vote driver**: positive (accumulating) = risk-on, negative (distributing) =
    /// risk-off.
    let mtdChangePercent: Double
}

/// Fetches the bond-flow reading. Behind a protocol so the coordinator runs with a stub on the
/// fixtures/tests path and the live network fetcher only in production — the same seam
/// `IndonesiaSovereignProviding` / `FREDMacroProviding` / `BIRateProviding` use.
nonisolated protocol BondFlowProviding: Sendable {
    /// The current bond-flow reading, or `nil` when the fetch fails or parses empty — the factor
    /// then drops, exactly like a missing macro series.
    func bondFlow() async -> BondFlowReading?
}

/// Fetches the bond-flow leg on-device from DJPPR Kemenkeu's public data API
/// (`api-djppr.kemenkeu.go.id`). Two unauthenticated GETs: the page payload (to discover the
/// latest month's media link, which carries a fresh GUID each month) then the linked PDF, whose
/// text is extracted with PDFKit and handed to the offline-testable `MacroParsing.parseSBNOwnership`.
/// Like the FRED / BI-rate / sovereign legs this is public data off its own host, so it rides a
/// plain `HTTPSession` (never the Stockbit client) outside the Stockbit anti-burst throttle.
nonisolated final class BondFlowService: BondFlowProviding {
    /// The "Kepemilikan SBN Domestik yang Dapat Diperdagangkan" page — its repeater lists the
    /// daily ownership files newest-first.
    private static let pageEndpoint =
        "https://api-djppr.kemenkeu.go.id/web/api/v1/page?url=kepemilikansbndomestikyangdapatdiperdagangkan"
    /// The site host the API is fronted from — sent as `Referer` (harmless, and some Kemenkeu
    /// endpoints gate bot traffic on it, mirroring the bi.go.id UA tactic).
    private static let referer = "https://djppr.kemenkeu.go.id/"

    private let session: any HTTPSession

    init(session: any HTTPSession) {
        self.session = session
    }

    func bondFlow() async -> BondFlowReading? {
        guard let pageURL = URL(string: Self.pageEndpoint),
              let pageJSON = await MacroHTTP.text(
                from: pageURL, headers: ["Referer": Self.referer], session: session),
              let link = MacroParsing.latestSBNFile(pageJSON),
              let mediaURL = URL(string: link),
              let pdf = await MacroHTTP.data(
                from: mediaURL, headers: ["Referer": Self.referer], session: session),
              let text = BondFlowPDF.text(from: pdf)
        else { return nil }
        return MacroParsing.parseSBNOwnership(text)
    }
}

/// The single impure boundary the bond-flow leg adds: PDF bytes → extracted text via PDFKit.
/// Kept tiny and separate so the parsing in `MacroParsing` stays pure (no PDFKit) and offline-
/// testable on the extracted text, exactly how `MacroHTTP` isolates the fetch from `MacroParsing`.
nonisolated enum BondFlowPDF {
    static func text(from data: Data) -> String? {
        PDFDocument(data: data)?.string
    }
}
