# Inputs: Discount Rates & Damodaran's Datasets

Read this when you need actual numbers for a discount rate, or when you want to
anchor an input (beta, margin, sales-to-capital, default spread) to a sector
benchmark. All formulas use **market values**, never book values, for weights.

## Contents
1. Risk-free rate
2. Equity risk premium (ERP) — implied vs historical
3. Beta — bottom-up, not regression
4. Cost of equity (CAPM)
5. Cost of debt — synthetic rating
6. WACC
7. Damodaran's annual datasets and how to use them

---

## 1. Risk-free rate

Use the yield on a **long-term (10-year) government bond in the currency of the cash
flows**. Dollar cash flows → US 10-year Treasury; euro cash flows → a AAA-rated
euro government bond, etc. For a currency with default risk, strip the country
default spread out of the local government-bond rate to get a true risk-free rate.

The risk-free rate also serves as the **ceiling on perpetual (terminal) growth** —
no firm out-grows its economy forever, and the risk-free rate is the proxy for
nominal growth in that currency.

---

## 2. Equity risk premium (ERP)

The ERP is the extra return investors demand for holding equities over the
risk-free asset. Two ways to get it:

**Implied ERP (Damodaran's preferred, forward-looking).** Solve for the discount
rate that sets the present value of expected aggregate cash flows (dividends +
buybacks) from the index equal to its current level — i.e., the internal rate of
return the market is currently pricing in, minus the risk-free rate. It updates
with prices and is not anchored to a historical period that may not repeat.
Damodaran publishes a monthly implied ERP for the S&P 500 and a current value on his
site; he recomputes it at the start of each month and after large market moves.

**Historical ERP (simpler, backward-looking).** The realized average premium of
stocks over bonds over a long horizon. Use the *geometric* average over the longest
reliable period, against the long-term bond. Weaknesses: high standard error and
the assumption that the past repeats.

**Country risk.** For a company exposed to riskier markets, add a country risk
premium on top of the mature-market ERP, scaled by the share of the business exposed
to that country. Damodaran publishes country-risk-premium and total-ERP tables by
country (derived from sovereign default spreads scaled up for equity volatility).

> Rule of thumb when no current figure is to hand: a mature-market implied ERP has
> historically sat roughly in the 4–6% range. Always prefer the actual current
> published value — note to the user that it should be refreshed from Damodaran's
> site (or via web search) since it moves with the market and your knowledge may be
> stale.

---

## 3. Beta — build it bottom-up

Do **not** trust a single-stock regression beta (high standard error, distorted by
the firm's own history). Build a **bottom-up beta**:

1. Identify the businesses the firm operates in and a set of comparable public peers.
2. Take the average **levered** (equity) beta of the peers.
3. **Unlever** it to strip out their financing:
   - Unlevered beta = Levered beta / [1 + (1 − tax rate) × (D/E)_peers]
4. If the firm operates in several businesses, take a revenue- or value-weighted
   average of the unlevered betas.
5. **Relever** to the subject firm's own capital structure:
   - Levered beta = Unlevered beta × [1 + (1 − tax rate) × (D/E)_firm]

This produces a more stable, fundamentals-based beta. Damodaran's datasets give
average levered **and** unlevered betas by industry, which lets you skip straight to
step 3/4.

---

## 4. Cost of equity (CAPM)

```
Cost of equity = Risk-free rate + Levered beta × Equity risk premium
```

Keep currency consistent: the risk-free rate and ERP must be in the same currency as
the cash flows. For multi-country exposure, the ERP is the exposure-weighted blend
from §2.

---

## 5. Cost of debt — use a synthetic rating

You want the rate the firm would borrow at *today*, not the coupon on old debt.

```
Pre-tax cost of debt = Risk-free rate + Default spread
After-tax cost of debt = Pre-tax cost of debt × (1 − marginal tax rate)
```

If the firm has a published bond rating, use the spread for that rating. If not,
compute a **synthetic rating** from the **interest coverage ratio**
(= EBIT / interest expense): higher coverage → better synthetic rating → lower
spread. Damodaran publishes the interest-coverage-ratio → rating → default-spread
table (with a separate, more forgiving table for smaller/riskier firms) and updates
the spreads annually.

Treat **operating leases as debt** (capitalize the lease commitments) and include
them in both the debt load and the coverage ratio — otherwise leverage and the cost
of debt are understated.

---

## 6. WACC

```
WACC = [E / (D + E)] × Cost of equity
     + [D / (D + E)] × After-tax cost of debt
```

- E = market value of equity (price × shares).
- D = market value of debt (approximate with book value if not traded, plus
  capitalized leases).
- Weights use market values. If you expect the capital structure to change over the
  forecast (common for young firms moving toward a mature D/E), let WACC change over
  time toward the target/industry structure rather than holding today's WACC forever.

---

## 7. Damodaran's annual datasets — what's there and how to use them

Damodaran posts free datasets on his NYU page, **updated every January**, covering
US, global, and regional markets. The ones that matter most for an input cross-check:

| Dataset | Use it to anchor |
|---------|------------------|
| Levered & unlevered betas by industry | Step 3–4 of the bottom-up beta |
| Cost of capital by sector | Sanity-check your WACC against the industry |
| Operating & net margins by industry | The terminal/target margin in a revenue-driven model |
| Sales-to-capital ratios by industry | Reinvestment in a revenue-driven model |
| Implied ERP (US, monthly) + country risk premiums | §2, and the macro backdrop |
| Default spreads by rating / interest-coverage ratio | §5, the synthetic-rating step |
| Effective & marginal tax rates by country/industry | The tax rate in FCFF and the cost of debt |
| Return on equity / return on capital by industry | Whether your ROIC/ROE assumptions are reasonable for the sector |

**How to use them:** treat the industry figure as the *prior*. If your firm's
assumed margin, ROIC, beta, or reinvestment differs materially from the industry,
that difference is a claim about the business that the story (Step 1 of the
workflow) must justify. A 25% margin in an industry that averages 8% is not wrong —
but it needs a moat to back it.

> The datasets are static as of each January. For anything fast-moving (the implied
> ERP especially, and current default spreads), tell the user to pull the latest
> figure from Damodaran's site or via web search rather than relying on a remembered
> value.
