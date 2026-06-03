# Models: FCFF, FCFE, and the Revenue-Driven Model

Read this when building the actual projection. It gives the cash-flow definitions,
the staged-model structures, and the revenue-driven model for young/high-growth
firms. Pair every model with the matching discount rate from `inputs.md`.

## Contents
1. Defining the cash flows (FCFF, FCFE)
2. Growth from fundamentals
3. Stable-growth (single-stage) model
4. Two-stage and three-stage models
5. The revenue-driven model (young / high-growth firms)
6. The firm → equity → per-share bridge
7. Worked skeleton

---

## 1. Defining the cash flows

**FCFF — free cash flow to the firm** (pre-debt, the operating business's cash):
```
FCFF = EBIT × (1 − tax rate)
     + Depreciation & amortization
     − Capital expenditures
     − Change in non-cash working capital
```
Equivalently: FCFF = EBIT(1−t) − Reinvestment, where
Reinvestment = (CapEx − D&A) + ΔNon-cash working capital.
Discount at **WACC** → enterprise (firm) value.

**FCFE — free cash flow to equity** (post-debt, what's left for shareholders):
```
FCFE = Net income
     + D&A − CapEx
     − Change in non-cash working capital
     − (Debt repaid − New debt issued)
```
Or, holding leverage at a target debt ratio DR (Damodaran's tidy form):
```
FCFE = Net income
     − (CapEx − D&A) × (1 − DR)
     − ΔNon-cash working capital × (1 − DR)
```
Discount at **cost of equity** → equity value directly.

For **financial firms**, CapEx and working capital aren't meaningful and debt is raw
material — value equity directly via dividends or FCFE defined through regulatory
capital, and do not use WACC.

---

## 2. Growth from fundamentals

Never type growth in directly; derive it:

- Operating-income growth = **Reinvestment rate × ROIC**
  - Reinvestment rate = Reinvestment / EBIT(1−t)
  - ROIC = EBIT(1−t) / Invested capital
- Net-income / EPS growth = **Retention ratio × ROE**
  - Retention ratio = 1 − payout ratio

The product form makes the engine explicit: value is created only when ROIC > cost
of capital, and faster growth then requires more reinvestment. Growth with ROIC ≈
cost of capital adds size but not value.

---

## 3. Stable-growth (single-stage) model

For mature firms growing at the economy's rate:
```
Firm value = FCFF₁ / (WACC − g)          where FCFF₁ = FCFF₀ × (1 + g)
Equity value = FCFE₁ / (Cost of equity − g)
```
Constraints (also in SKILL.md): **g ≤ risk-free rate**, and reinvestment must equal
**g / ROIC** so the growth is funded. With ROIC drifting to the cost of capital in
maturity, the reinvestment rate ≈ g / WACC.

---

## 4. Two-stage and three-stage models

**Two-stage:** an explicit high-growth period (typically 5–10 years), then a
perpetuity.
```
Value = Σ [ CFt / (1 + r)^t ]  for t = 1..n      (high-growth phase)
      + [ TVn / (1 + r)^n ]                       (discounted terminal value)

TVn = CF₍n+1₎ / (r − g_stable)
```
where r is WACC (FCFF) or cost of equity (FCFE), and CF is the matching cash flow.

**Three-stage:** high growth → a **transition phase** where growth, margins, and
reinvestment glide linearly toward stable levels → perpetuity. Use it when jumping
straight from high growth to stable growth would be implausible (most genuinely
high-growth firms). The transition phase is where you also fade ROIC toward the cost
of capital and move the capital structure toward the industry target.

**Discipline across stages:** as growth steps down, reinvestment should step down
with it (less growth needs less reinvestment), which *raises* the cash-flow payout
in later years. If your model has growth falling but reinvestment staying high, the
cash flows are being understated.

---

## 5. The revenue-driven model (young / high-growth firms)

When earnings are negative or margins aren't yet established, you can't grow off
current EBIT. Drive the model top-down instead:

1. **Forecast revenue growth** from the story and market size (TAM × plausible
   share). Front-load high growth, fade it toward the economy.
2. **Set a target operating margin** the firm reaches at maturity — anchor it to the
   industry margin from the datasets, adjusted up only for a defensible edge. Glide
   the current (often negative) margin to the target over the forecast.
3. **Derive reinvestment from the sales-to-capital ratio:**
   ```
   Reinvestment in year t = (Revenue_t − Revenue_t−1) / (Sales-to-capital ratio)
   ```
   The sales-to-capital ratio (anchor to the industry dataset) says how much
   incremental capital each dollar of new revenue needs. This is how the model makes
   the firm *pay* for its growth.
4. **Build FCFF each year:** FCFF = Revenue × Operating margin × (1 − tax rate) −
   Reinvestment. (Apply taxes only once the firm turns profitable / uses up loss
   carryforwards.)
5. **Terminal value** as in §3, once the firm is mature.
6. **Adjust for failure risk** if the firm could go under: value the going concern,
   then probability-weight against a distress/liquidation value
   (Value = p(survival) × going-concern value + p(failure) × distress value).

This is the model behind Damodaran's well-known young-company valuations — the
output is highly sensitive to the revenue, margin, and sales-to-capital
assumptions, so always show those sensitivities.

---

## 6. The firm → equity → per-share bridge

From an **FCFF** valuation you have enterprise/firm value. Convert:
```
  Firm (enterprise) value
+ Cash & marketable securities
+ Value of cross-holdings / non-operating assets
− Market value of debt (incl. capitalized leases)
− Minority interests
− Value of employee/management options (or build expected dilution into share count)
= Equity value
÷ Shares outstanding
= Intrinsic value per share
```
An **FCFE** valuation lands on equity value directly, but still needs the
options/dilution adjustment before dividing by shares.

---

## 7. Worked skeleton (two-stage FCFF)

Use this as a layout, not as filled-in numbers:

```
Story & lifecycle:        [3–5 sentences; stage = Growth]
Discount rate (WACC):     Rf + β×ERP for Ke; synthetic-rating Kd; market-value weights  → r
High-growth phase (yrs 1–n):
  Revenue / EBIT growth:  from reinvestment rate × ROIC
  FCFF_t:                 EBIT_t(1−t) − Reinvestment_t
  PV of each FCFF_t:      FCFF_t / (1+r)^t
Terminal (year n):
  g_stable ≤ Rf
  reinvestment = g_stable / ROIC_stable
  TV = FCFF_(n+1) / (r − g_stable);  PV = TV / (1+r)^n
Firm value:               Σ PV(FCFF) + PV(TV)
Bridge:                   + cash + cross-holdings − debt − minorities − options
Per share:                ÷ shares
Cross-check:              EV/EBITDA & EV/Sales vs peers (controlling for margin/ROC)
Value vs price:           value, price, gap %, thesis + catalyst
Sensitivities:            terminal g, r, terminal margin
```

A note Damodaran stresses: the bulk of the value in most DCFs sits in the terminal
value. That is not a flaw, but it means the terminal assumptions deserve the most
scrutiny — and it is why the constraints in §3 (g ≤ Rf, funded reinvestment, fading
excess returns) are non-negotiable.
