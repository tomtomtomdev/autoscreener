---
name: damodaran-valuation
description: >-
  Value a business using Aswath Damodaran's intrinsic, cash-flow-based valuation
  framework: discounted cash flow (FCFF and FCFE), bottom-up cost of capital,
  fundamentals-driven growth, disciplined terminal value, and a relative-valuation
  cross-check. Use this skill whenever the user wants to estimate the intrinsic or
  "fair" value of a company or stock, build or sanity-check a DCF, figure out a
  discount rate / WACC / cost of equity, work out a terminal value, justify or
  decompose a multiple (PE, PEG, EV/EBITDA, EV/Sales, P/B), turn a business
  "story" into a number, or decide whether a stock's price is justified by
  fundamentals. Also trigger for "what's this company worth", "is this stock
  cheap on fundamentals", "model the cash flows", "estimate fair value", or when
  layering valuation on top of a Fisher/Lynch/Graham/Buffett/Zweig screen. This is
  the rigor layer producing the value number a margin of safety applies to — use it
  even if the user never says "DCF".
---

# Damodaran Intrinsic Valuation

This skill encodes the valuation approach taught by Aswath Damodaran (NYU Stern):
**value comes from the cash flows a business generates, the growth in those cash
flows, and the risk in those cash flows — nothing else.** Multiples, charts, and
sentiment are price signals; this skill is about *value*. The investing decision
lives in the gap between the two.

Core mantra to keep visible throughout: **"A valuation is a story converted into
numbers, and the numbers are only as good as the story is possible, plausible, and
probable."** Every input must trace back to a defensible narrative about the
business.

## When to reach for the reference files

Keep this file in context for the workflow and decision logic. Pull in:

- `references/inputs.md` — building discount rates: risk-free rate, equity risk
  premium (implied vs historical), bottom-up beta, cost of debt via synthetic
  rating, WACC, and how to use Damodaran's annual datasets. Read this whenever you
  need an actual discount-rate number.
- `references/models.md` — the model variants (stable / 2-stage / 3-stage FCFF and
  FCFE, the revenue-driven model for young or high-growth firms) with the full
  formula set and a worked skeleton. Read this when you're actually building the
  projection.

## The valuation workflow

Work through these in order. Do not skip to a number.

### 1. Tell the story first

Before touching a spreadsheet, write 3–5 sentences answering: What does this
business do, what is its addressable market, how does it make money, what could go
right, what could go wrong? The story dictates every input. A "big market, low
margin, capital-light" story and a "niche, high margin, capital-heavy" story
produce completely different models for the same revenue.

Classify the firm by **lifecycle stage** — this drives method choice:

| Stage | Cash flows | Best handled with |
|-------|-----------|-------------------|
| Young / start-up | Negative or tiny, huge growth | Revenue-driven model (see models.md), narrative-heavy |
| Growth | Positive, reinvesting heavily | 2- or 3-stage FCFF |
| Mature | Stable, high payout | Stable-growth or 2-stage FCFE/FCFF |
| Decline | Shrinking, divesting | Stable model with g ≤ 0, watch for distress/liquidation value |

This lifecycle lens maps cleanly onto Lynch's categories (fast growers, stalwarts,
slow growers, turnarounds) — use the screening skills to *find* the candidate, use
this skill to *price* it.

### 2. Choose FCFF or FCFE

- **FCFF (free cash flow to the firm)** → discount at **WACC** → gives **enterprise
  value**; subtract net debt to reach equity value. Default choice. Best when
  leverage is changing or you want a leverage-neutral view of the operating
  business.
- **FCFE (free cash flow to equity)** → discount at **cost of equity** → gives
  **equity value directly**. Use for stable-leverage firms (especially financials,
  where debt is raw material and FCFF is ill-defined).

**The cardinal rule: never mismatch.** FCFF pairs with WACC, FCFE pairs with cost
of equity. Mixing them is the single most common DCF error.

### 3. Build the discount rate (see `references/inputs.md`)

Bottom-up, not plucked from the air:
- Cost of equity = Risk-free rate + Bottom-up beta × Equity risk premium
- After-tax cost of debt = (Risk-free rate + default spread) × (1 − tax rate)
- WACC = E/(D+E)·cost of equity + D/(D+E)·after-tax cost of debt (market-value weights)

Match the **currency and real/nominal basis** of the discount rate to the cash
flows. A rupee cash flow discounted at a dollar rate is meaningless.

### 4. Project cash flows from fundamentals, not from a typed-in growth %

Growth is *earned*, not assumed. Tie it to reinvestment and returns:

- Expected growth in operating income = **Reinvestment rate × Return on invested
  capital (ROIC)**
  - Reinvestment rate = (Net CapEx + ΔNon-cash working capital) / EBIT(1−t)
- Expected growth in EPS = **Retention ratio × Return on equity (ROE)**

If someone hands you "15% growth," ask what reinvestment and what return on capital
produce it. High growth with no reinvestment is a free lunch that does not exist —
flag it.

For young/high-growth firms, drive the model off **revenue growth → target
operating margin → sales-to-capital ratio** instead (see models.md). The
sales-to-capital ratio converts revenue growth into the reinvestment it requires.

### 5. Terminal value — where most of the value lives, so get it disciplined

TV (at end of high-growth period) = FCFF₍next year₎ / (WACC − g_stable)

Hard constraints — violate these and the valuation is broken:
- **g_stable ≤ risk-free rate.** A firm cannot grow faster than the economy
  forever; Damodaran uses the risk-free rate as the cap on perpetual nominal
  growth (it proxies nominal GDP growth in that currency). Often the honest choice
  is *lower*.
- In the stable phase, reinvestment must be consistent with growth:
  **stable reinvestment rate = g_stable / ROIC_stable.** You cannot grow 3% forever
  while reinvesting nothing.
- Mature-firm ROIC should drift toward the cost of capital (excess returns fade as
  competition arrives). Only justify a permanent ROIC > WACC with a genuine,
  durable moat — this is exactly where the Buffett/Graham quality filters earn
  their keep.

### 6. Bridge to per-share value

Firm value (from FCFF) → add cash & cross-holdings → subtract debt → subtract
minority interests → subtract the value of management options / expected dilution →
divide by shares outstanding. (FCFE skips straight to equity value but still needs
the options adjustment.)

### 7. Value vs. price — state the thesis

Report intrinsic value, then the current price, then the gap as a percentage. The
gap is not the conclusion; it is the hypothesis. Note explicitly: what would have
to be true for the market to be right, and what catalyst closes the gap. A cheap
stock with no catalyst can stay cheap indefinitely.

## Decision tree: which model?

```
Is the firm financial (bank/insurer)?
├─ Yes → FCFE / dividend-based, equity reinvestment via regulatory capital. WACC is meaningless here.
└─ No
   ├─ Revenue small/negative, margins not yet established, growth huge?
   │     → Revenue-driven model (models.md): growth → margin → sales-to-capital.
   ├─ Clearly mature, stable margins & leverage, growth ≈ economy?
   │     → Single-stage stable-growth FCFF.
   └─ Growing above the economy but identifiable path to maturity?
         → 2-stage (high growth → stable) or 3-stage (high → transition → stable) FCFF.
```

## Relative-valuation cross-check (always do this)

After the DCF, sanity-check against multiples. Damodaran's framing: every multiple
has a **companion variable** — the one fundamental that should drive it. Compare a
firm to peers *on the multiple after controlling for the companion variable*.

| Multiple | Companion variable (what really drives it) |
|----------|--------------------------------------------|
| PE | Expected growth (this is what PEG tries, crudely, to control for) |
| PEG | Growth — but only valid if growth rates across the peer set are comparable |
| EV/EBITDA | Reinvestment needs + return on capital + tax rate |
| EV/Sales | Operating margin (a low PSR is only cheap if margins justify it) |
| P/B | Return on equity (P/B vs ROE is the single most useful value scatter) |

A stock that looks cheap on the multiple but cheap *for a reason* in the companion
variable is not actually cheap. This is the rigor that turns Fisher's PSR screen or
Lynch's PEG rule of thumb into a defensible judgment.

## How this layers with the rest of the investing suite

- **Fisher (Super Stocks / PSR)** screens candidates → here, justify the PSR with
  EV/Sales-vs-margin and a full FCFF if the margin story holds.
- **Lynch (categories / PEG)** validates growth → here, convert PEG into an actual
  reinvestment-and-ROIC growth model and confirm the growth is paid for.
- **Graham & Buffett (quality / moat / margin of safety)** → this skill produces the
  intrinsic value *number*; their margin of safety is the discount you demand off it,
  and their moat test is what licenses a permanent excess-return assumption in the
  terminal value.
- **Zweig (monetary / momentum)** times the market → Damodaran's **implied equity
  risk premium** is the valuation-based macro companion to Zweig's indicators: a low
  implied ERP means the whole market is priced for low forward returns, regardless of
  momentum.

## Sanity checklist (run before reporting any value)

- [ ] Cash flows and discount rate match (FCFF↔WACC, FCFE↔cost of equity).
- [ ] Currency and real/nominal basis are consistent across cash flows and rate.
- [ ] Terminal growth ≤ risk-free rate, and ideally justified, not maxed out.
- [ ] Terminal reinvestment rate = g/ROIC (growth is funded).
- [ ] Any permanent ROIC > WACC is backed by a real, durable moat.
- [ ] Growth is tied to reinvestment × return, not typed in.
- [ ] R&D capitalized for research-heavy firms; leases treated as debt.
- [ ] Cash, cross-holdings, debt, minorities, and option dilution all handled in the bridge.
- [ ] Inputs (beta, ERP, margins, sales-to-capital, default spread) cross-checked
      against Damodaran's industry datasets (see inputs.md).
- [ ] A relative-valuation cross-check was done and reconciled with the DCF.
- [ ] Value, price, the gap, and the implied thesis (+ catalyst) are all stated.

## Output format

Present results as:

1. **Story** (3–5 sentences) and lifecycle classification.
2. **Key inputs** in a small table: discount rate and its components, growth path,
   margins, reinvestment, terminal assumptions.
3. **Intrinsic value** per share, with the firm→equity bridge shown.
4. **Relative-valuation cross-check** and how it reconciles.
5. **Value vs. price**, the gap, and the thesis + catalyst.
6. **Key sensitivities** — name the 2–3 inputs the value is most sensitive to
   (almost always: terminal growth, discount rate, terminal margin) and show how the
   value moves. Honesty about uncertainty beats false precision.

Never present a single point estimate as if it were exact. The output of a valuation
is a considered range and a clear view of what drives it.
