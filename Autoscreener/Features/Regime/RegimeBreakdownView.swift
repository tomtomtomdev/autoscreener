import SwiftUI

/// The full top-down regime breakdown (`idx-investing-research.md` §3): the
/// synthesised risk-on / neutral / risk-off stance, the transparent factor
/// breakdown that produced it, and — when it fired — the late-cycle guard note.
/// Framed as a *posture*, never a forecast (Howard Marks: you can prepare, not
/// predict).
///
/// Rendered inline atop `MarketsView` (no longer a pushed detail page), so it owns
/// no scroll container or navigation title of its own — the host supplies both. The
/// host only mounts this once a read exists, so this view always has data; loading
/// and empty states live in `MarketsView`.
struct RegimeBreakdownContent: View {
    let read: RegimeRead

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            Divider()
            factorList
            if read.valuationCapped { cappedNote }
            if read.tapeFloored { tapeNote }
            footnote
        }
    }

    // MARK: - Header (the stance)

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(read.stance.rawValue)
                    .font(.largeTitle.bold())
                    .foregroundStyle(RegimeColors.color(read.stance))
                    .accessibilityIdentifier("regime.stance")
                Spacer()
                if let asOf = read.asOf {
                    Text("valuation as of \(asOf)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(read.stance.guidance)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Factors

    private var factorList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What's driving it")
                .font(.headline)
                .padding(.bottom, 8)
            ForEach(read.factors) { factor in
                factorRow(factor)
                if factor.id != read.factors.last?.id { Divider() }
            }
        }
    }

    private func factorRow(_ factor: RegimeFactor) -> some View {
        HStack(alignment: .top, spacing: 12) {
            signalPill(factor.signal)
            VStack(alignment: .leading, spacing: 2) {
                Text(factor.kind.rawValue)
                    .font(.body.weight(.medium))
                Text(factor.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .accessibilityIdentifier("regime.factor.\(factor.kind.rawValue)")
    }

    private func signalPill(_ signal: RegimeSignal) -> some View {
        Text(signal.rawValue)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RegimeColors.color(signal), in: Capsule())
            .frame(width: 72, alignment: .center)
            .fixedSize()
    }

    // MARK: - Notes

    private var cappedNote: some View {
        Label {
            Text("Valuation guard: the tape is constructive, but the index is stretched versus its own history — so the read is held at neutral rather than risk-on. Being aggressive when prices are high is as dangerous as being timid when they're cheap.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.orange)
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("regime.cappedNote")
    }

    private var tapeNote: some View {
        Label {
            Text("Tape guard: the index is cheap, but it's below its 200-day average and LQ45 breadth has collapsed — a broad, confirmed downtrend. Don't fight the tape: the read is forced to defence. Cheap doesn't mean going up soon; accumulate slowly, don't size up into a falling market.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "arrow.down.right.circle.fill")
        }
        .foregroundStyle(.red)
        .padding(12)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("regime.tapeNote")
    }

    private var footnote: some View {
        Text("A posture for how aggressive to be given where the cycle sits — not a market forecast. Valuation is weighted most heavily as the dominant driver of future risk.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Colour mapping for the regime stance/signal. Kept in the UI layer (shared by
/// `RegimeBreakdownContent` and `MarketsView`) so the models stay UI-free.
enum RegimeColors {
    static func color(_ stance: RegimeStance) -> Color {
        switch stance {
        case .riskOn: .green
        case .neutral: .yellow
        case .riskOff: .red
        }
    }

    static func color(_ signal: RegimeSignal) -> Color {
        switch signal {
        case .riskOn: .green
        case .neutral: .gray
        case .riskOff: .red
        }
    }
}
