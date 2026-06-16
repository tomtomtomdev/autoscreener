# Selection-gate strictness — 4-bug fix plan

Tracks the four over-strict / near-impossible conditions found while auditing the selection
pipeline "from step 2 onward" (hard gates → governance → MoS). All live in
`Autoscreener/Features/Selection/StockSelectionEngine.swift`, production preset `.balanced`.
Each item is grounded in the listed investing skills, not priors.

## Status

| # | Issue | Severity | Status |
|---|-------|----------|--------|
| 1 | NCAV combined with the Graham number via `min` (ceiling) instead of `max` (floor) | 🔴 incorrect | ✅ **DONE** — commit `533b5d6` |
| 2 | Bank justified-P/B MoS structurally excludes quality IDX banks | 🟠 over-strict (calibration) | ⏳ planned — needs a decision |
| 3 | Industrial `SolvencyGate` current-ratio ≥ 1.0 false-negatives negative-WC businesses | 🟡 over-strict | ⏳ planned |
| 4 | Loss-makers / trough cyclicals auto-eliminated (IV = 0 on TTM EPS ≤ 0) | 🟡 over-strict | ✅ **DONE** — *Targeted* variant |

Workflow for each (non-negotiable, per `CLAUDE.md`): green baseline → failing regression test
(Kent Beck Regression Test pattern) → minimal production fix → green + golden master → commit.

---

## ✅ 1. NCAV as a value floor, not a ceiling — DONE

**Was:** `GrahamValuator.intrinsicValue` returned `min(Graham number, NCAV)`, valuing cash-rich
names *below* their own net-current-asset (liquidation) value and sinking the MoS gate for every
positive-NCAV name.
**Fix:** `min` → `max` (NCAV can only raise intrinsic value). Grounded in `intelligent-investor`
(Graham number = fair-value ceiling; NCAV = separate net-net screen) + `graham-financial-statements`
(NCAV = liquidation floor; a business is worth at least its net liquid assets).
**Tests:** new `GrahamValuatorTests` (red→green); repaired impossible characterization fixtures
(`currentAssets > totalAssets`) to consistent negative-NCAV balance sheets, golden master
byte-for-byte; WIFI end-to-end IV corrected 6,364 → 8,000. Full `AutoscreenerTests`: SUCCEEDED.
See `SPEC.md` (2026-06-16) and memory `graham-valuator-ncav-floor-fix`.

---

## ⏳ 2. Bank justified-P/B MoS structurally excludes quality banks

**Where:** `JustifiedPBValuator` / `BankValuation.justifiedPriceToBook` (~line 699); bank params
line 326 (`riskFreeRate 0.065, equityRiskPremium 0.07, beta 1.1` ⇒ `Ke = 0.142`).

**Diagnosis.** `IV = justifiedP/B × BVPS`, `justifiedP/B = (ROE − g)/(Ke − g)`. With Ke ≈ 14.2 %:
- ROE 15 %, payout 40 % ⇒ justified P/B ≈ **1.10×** ⇒ neutral MoS 0.30 needs price ≤ **0.77× book**.
- ROE 20 % ⇒ justified P/B ≈ 1.75× ⇒ neutral needs ≤ **1.23× book**.
- Risk-off (MoS 0.45) ⇒ ≤ **0.61× book** (distressed-only).

BBCA trades ~4–5× book, BMRI/BRIS ~2× ⇒ the best IDX banks can *never* qualify. This is a
**calibration judgment**, not a clear logic bug like #1 — a deep-value purist would defend it.

**Grounding to consult before fixing:** `damodaran-valuation` (cost of equity / justified multiples
— is Ke 14.2 % too high? Indonesian 10y ≈ 6.5 % Rf is reasonable, but β 1.1 + ERP 7 % may be
aggressive for a deposit-funded bank), `essays-of-warren-buffett` / `buffett-shareholder-letters`
(a wonderful bank at a fair price vs a fair bank at a wonderful price), `howard-marks` (is "never
buy a quality bank" the right posture across the whole cycle?).

**Candidate fixes (need user decision — pick one):**
- (a) **Re-calibrate Ke inputs** (lower β and/or ERP, or measure β like the industrial timing leg
  already does via `FactorRegression`). Raises justified P/B so quality banks become reachable.
- (b) **Separate, lower MoS floor for the financial archetype** (banks rarely trade at deep
  net-net-style discounts; a 10–20 % floor may be the right risk-adjusted bar).
- (c) **Leave as-is** and document it as an intentional deep-value stance (only cheap banks pass).

**Test approach:** characterize current BBCA-shaped IV/MoS (the `EndToEndAuditTrailTests` BBCA
fixture already does), add a regression test pinning the *intended* post-decision behavior, verify
the bank golden-master path.

**Blast radius:** `EndToEndAuditTrailTests` BBCA cases (IV ≈ 4,343; screened-out-at-5,066), any
bank fixtures in `BankProfileTests`. Industrial path untouched.

---

## ⏳ 3. Industrial SolvencyGate current-ratio ≥ 1.0 false-negatives negative-WC businesses

**Where:** `SolvencyGate.evaluate` (line 524): `if s.ttm.currentRatio < config.solvency.minCurrentRatio
{ fail }`; `.balanced` sets `minCurrentRatio: 1.0` (line 298).

**Diagnosis.** Many healthy IDX names run current ratio < 1.0 *by design* — telcos (TLKM),
retailers, consumer staples financed by suppliers (negative working capital). They hard-fail before
scoring despite being sound. By Graham's *own* standard (≥ 2.0 for industrials) 1.0 is already lax,
but `graham-financial-statements` explicitly flags that the 1930s thresholds break for "modern
asset-light or regulated" businesses — lean on the reasoning, not the number.

**Candidate fixes:**
- (a) **Sector-aware floor** — exempt or relax the current-ratio test for negative-WC sectors
  (telco/retail/staples/utilities), keeping it for the rest.
- (b) **Swap to a more robust solvency measure** — interest-coverage (times-interest-earned) and/or
  quick ratio, which don't penalize fast-turn negative-WC models. (Graham's coverage standards are
  in the skill's ratios reference.)
- (c) **Lower the floor** (e.g. 0.8) — crude but simple; still catches the genuinely illiquid.

Recommended: (a) or (b); both need a sector signal — `SecurityData.sector` exists, so a sector→
policy map is feasible.

**Test approach:** regression test with a TLKM-shaped negative-WC-but-solvent fixture that currently
fails Solvency and should pass; assert it now reaches scoring. Keep a genuinely-insolvent fixture
failing.

**Blast radius:** `GateCharacterizationTests.solvencyFailsOnLowCurrentRatio`, `ExitEvaluatorTests`
(Solvency tier-1a exit), any fixture relying on the flat 1.0 floor. Moderate.

---

## ✅ 4. Loss-makers / trough cyclicals auto-eliminated — DONE (*Targeted* variant)

**Decision (user, 2026-06-16):** of the two viable approaches the audit surfaced, took the **Targeted**
one — use the 3-yr average EPS *only when the trailing TTM EPS ≤ 0*; keep TTM EPS while positive. This
fixes the documented elimination bug with a **byte-for-byte golden master** (no current fixture has a
negative TTM EPS, so no end-to-end / characterization assertion moved) and *no audit-trail inconsistency*
(profitable names use TTM EPS in both the valuator and `GrahamValueScorer`; a trough name simply skips the
scorer's MoS sub-credit, so the two never print conflicting Graham numbers). The rejected "Graham-pure"
variant (always average, in valuator *and* scorer) would have been more literal but intentionally churned
the GOOD/WIFI composite/weight/audit golden values.

**Why this is grounded, not a fixture hack.** `intelligent-investor` is explicit that the Graham Number's
earnings input is the **average of the last 3 years** (and the defensive P/E test is "≤ 15× average
earnings, last 3 years"). Trailing EPS is the natural input while positive; the multi-year average is the
safeguard against a single anomalous down year — applied precisely when the trailing year is a loss.

**Fix:** new `GrahamValuator.grahamEPS(_:config:)` — returns TTM EPS when `> 0`, else the average of
`financials.suffix(normalizedEpsYears)` net income ÷ shares (years with 0 shares filtered; TTM value
stands if no usable history). New config field `ValuationParams.normalizedEpsYears` (= 3 in `.balanced`;
`SelectionConfig` is `Codable` but never persisted, so the added field breaks nothing). NCAV path
untouched.

**Tests (Regression Test pattern, `GrahamValuatorTests`):** `troughYearDoesNotZeroANormallyProfitableCyclical`
(NI [150,170,−20], TTM −20 ⇒ avg 100 ⇒ IV √(22.5·100·1000) = 1,500; was 0 — **red→green**);
`persistentLossMakerStaysExcludedAtZeroIntrinsicValue` (NI [−30,−20,−10] ⇒ avg < 0 ⇒ IV 0 — no-regression);
`positiveTrailingYearStillUsesTTMEPSNotTheAverage` (TTM 150 > avg 110 ⇒ IV uses 150, pins the Targeted
decision). Full `AutoscreenerTests`: **780 passing, TEST SUCCEEDED**, golden master byte-for-byte.

### Original plan (kept for reference)

**Where:** `GrahamValuator.intrinsicValue` uses **`s.ttm.eps`** (single trailing year). If TTM
EPS ≤ 0 (and NCAV ≤ 0) ⇒ no candidate ⇒ IV 0 ⇒ `marginOfSafety` returns −1 ⇒ MoS gate fails.

**Diagnosis.** Every loss-maker and bottom-of-cycle commodity name is dropped before scoring.
Excluding genuine loss-makers is intended (Graham wants earnings), but using a *single trough year*
also wrongly kills cyclicals that are normally profitable.

**Clean grounded fix.** `intelligent-investor` is explicit: the Graham Number uses **"EPS = average
of the last 3 years"**, not the latest year. The code uses TTM EPS. Switching the Graham number to
**average (normalized) EPS over the recent window** (the financials are already on hand) is *both*
more Graham-correct *and* less strict — a single down year no longer zeroes intrinsic value, while a
persistent loss-maker (negative average) is still correctly excluded.

**Proposed fix:** compute the Graham-number EPS as the average of `financials.suffix(N)` net income /
shares (or a dedicated normalized-EPS helper), guarded `> 0`. Keep BVPS as TTM. Leave the
genuinely-unprofitable (negative average + NCAV ≤ 0 ⇒ IV 0 ⇒ excluded) behavior intact.

**Test approach (Regression Test pattern):**
- trough cyclical: one negative TTM year but positive 3-yr average ⇒ IV now > 0, MoS computable
  (was IV 0 / excluded). Red→green.
- persistent loss-maker: negative average ⇒ still IV 0 ⇒ excluded (no-regression).
- steady earner: average ≈ TTM ⇒ IV ≈ unchanged (golden-master neutral, or update the one fixture).

**Blast radius:** changes the Graham number for any name whose 3-yr average EPS ≠ TTM EPS — i.e. the
golden-master fixtures (which use flat/rising EPS). The characterization `defaultFinancials` has
rising NI (TTM 140 vs 3-yr avg 130), so IV would shift ≈ 2,012 → ≈ √(22.5·130·1200) ≈ 1,936 unless
the fixture's EPS series is flattened. **Decide:** flatten fixture EPS to keep golden master
byte-for-byte, or update the golden values intentionally (like the WIFI change in #1).

---

## Suggested order

1. **#4** next — it's the cleanest (a grounded one-spot change with a clear test story), and it
   pairs naturally with #1 (both are `GrahamValuator` correctness).
2. **#3** — mechanical once a sector-policy seam is chosen.
3. **#2** — last; it's a calibration call that wants an explicit user decision (which of a/b/c) and
   ideally a live BBCA/BMRI sanity check against the authenticated feed.
