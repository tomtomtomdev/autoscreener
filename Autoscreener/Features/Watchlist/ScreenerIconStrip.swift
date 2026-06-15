import SwiftUI

/// Presentation grouping for a Bandar screener — drives the icon tint in the Watchlist strip.
///
/// Lives in the view layer (not on the `Codable`/`Sendable` domain `BandarScreenerKind`) so the
/// model stays SwiftUI-free. The five families mirror the natural sections of the screener master:
/// bandar accumulation, foreign flow, price/volume activity, fundamentals, and the liquidity gates.
enum ScreenerFamily {
    case bandar, foreign, activity, fundamental, liquidity

    var tint: Color {
        switch self {
        case .bandar:      return .purple
        case .foreign:     return .teal
        case .activity:    return .orange
        case .fundamental: return .green
        case .liquidity:   return .secondary
        }
    }
}

/// Pure, view-free mapping from a screener kind to its presentation (SF Symbol + family), plus the
/// rule for *which* of a row's matched screeners to render. Kept `static` so it is unit-testable
/// without rendering any SwiftUI.
enum ScreenerIconCatalog {
    /// SF Symbol for a screener. Reuses the symbols already chosen for the (now-removed) sidebar rows
    /// in `SidebarItem.systemImage`, so the icon vocabulary stays consistent across the app.
    static func symbol(for kind: BandarScreenerKind) -> String {
        switch kind {
        case .accumulating:     return "chart.bar.doc.horizontal"
        case .aboveMA20:        return "chart.line.uptrend.xyaxis"
        case .shiftToday:       return "arrow.left.arrow.right.circle"
        case .accumDistPositive: return "arrow.up.circle"
        case .foreignFlow1M:    return "globe.asia.australia"
        case .foreignFlow6M:    return "globe.europe.africa"
        case .foreignFlow3M:    return "globe.americas"
        case .foreignBuyStreak: return "flame.fill"
        case .freshForeignBuy:  return "sparkles"
        case .freqSpike:        return "waveform.path.ecg"
        case .volumeSpike:      return "chart.bar.fill"
        case .above50MA:        return "chart.xyaxis.line"
        case .above200MA:       return "chart.line.uptrend.xyaxis.circle"
        case .earningsYield:    return "percent"
        case .pbvBelow2:        return "tag"
        case .roeQuality:       return "checkmark.seal"
        case .fcfPositive:      return "dollarsign.circle"
        case .manageableDebt:   return "scalemass"
        case .liquidityFloor:   return "drop.fill"
        case .intradayLiquidity: return "bolt.fill"
        }
    }

    /// Which family a screener belongs to — drives the icon tint.
    static func family(for kind: BandarScreenerKind) -> ScreenerFamily {
        switch kind {
        case .accumulating, .aboveMA20, .shiftToday, .accumDistPositive:
            return .bandar
        case .foreignFlow1M, .foreignFlow6M, .foreignFlow3M, .foreignBuyStreak, .freshForeignBuy:
            return .foreign
        case .freqSpike, .volumeSpike, .above50MA, .above200MA:
            return .activity
        case .earningsYield, .pbvBelow2, .roeQuality, .fcfPositive, .manageableDebt:
            return .fundamental
        case .liquidityFloor, .intradayLiquidity:
            return .liquidity
        }
    }

    /// The screeners to render for a watchlist row: the non-veto *signal* screeners only, in canonical
    /// `allCases` order (stable, deterministic layout). The two liquidity veto gates are excluded —
    /// every surviving watchlist row passed both, so their icons would be constant noise on every row.
    static func displayed(from matched: Set<BandarScreenerKind>) -> [BandarScreenerKind] {
        BandarScreenerKind.allCases.filter { matched.contains($0) && !$0.isVeto }
    }
}

/// A horizontal strip of small tinted icons — one per signal screener a stock satisfies. Rendered in
/// the Watchlist column to the right of the score; each icon's hover tooltip names its screener.
struct ScreenerIconStrip: View {
    let kinds: Set<BandarScreenerKind>
    /// Tapping an icon asks the host to push that screener's full results list. Optional/defaulted so
    /// non-interactive call sites (and previews) keep rendering plain icons.
    var onSelect: ((BandarScreenerKind) -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ScreenerIconCatalog.displayed(from: kinds), id: \.self) { kind in
                Button {
                    onSelect?(kind)
                } label: {
                    Image(systemName: ScreenerIconCatalog.symbol(for: kind))
                        .font(.caption)
                        .foregroundStyle(ScreenerIconCatalog.family(for: kind).tint)
                }
                .buttonStyle(.plain)
                .disabled(onSelect == nil)
                .help(kind.displayName)
                .accessibilityIdentifier("watchlist.screener-\(kind.rawValue)")
            }
        }
    }
}
