---
name: intelligent-investor
description: >
  Apply Benjamin Graham's value investing framework from The Intelligent Investor to stock analysis,
  portfolio decisions, and market behavior interpretation. Use this skill whenever the user wants to
  analyze a stock using fundamental value principles, assess margin of safety, distinguish speculation
  from investment, evaluate market sentiment through Mr. Market lens, or apply defensive vs. enterprising
  investor frameworks. Trigger when user mentions Graham, value investing, intrinsic value, margin of
  safety, defensive portfolio, or asks whether a stock is "cheap" or "fairly valued" by fundamentals.
  Also trigger when user wants to analyze IDX stocks through a fundamental lens or combine Graham
  principles with Indonesian market context.
---

# The Intelligent Investor – Graham Framework Skill

Apply Benjamin Graham's principles from *The Intelligent Investor* (1949, revised 1973) to real stock
analysis and portfolio decisions. This skill is grounded in the book's core ideas but adapted for
practical application, including on emerging markets like IDX.

---

## Core Concepts Reference

### 1. Investment vs. Speculation (Chapter 1)
> "An investment operation is one which, upon thorough analysis, promises safety of principal and an
> adequate return. Operations not meeting these requirements are speculative."

**How to apply:**
- Ask: Is this based on analysis, or on hope/momentum?
- Buying a stock because it's rising = speculation
- Buying because intrinsic value > price = investment
- On IDX: bandar-driven price action is speculative territory unless fundamentals align

---

### 2. Mr. Market (Chapter 8) — Most Practical Concept
Graham's allegory: imagine a manic-depressive business partner who offers to buy or sell his share
every day at wildly varying prices. His mood is your opportunity, not your guide.

**How to apply:**
- Market price ≠ business value
- Use price drops as buying opportunities, not panic signals
- Use price surges to sell if price exceeds intrinsic value
- Never let Mr. Market's mood dictate your decisions

**IDX context:** Mr. Market on IDX is especially manic — thin liquidity + retail dominance +
bandar activity = extreme mood swings. This amplifies both the opportunity and the danger.

---

### 3. Margin of Safety (Chapter 20) — The Central Principle
Buy only when price is significantly *below* estimated intrinsic value. The gap is your margin of
safety against errors in analysis, bad luck, or market irrationality.

**Graham's rule of thumb:** Buy at 2/3 or less of intrinsic value (i.e., 33%+ discount).

**How to apply:**
1. Estimate intrinsic value (see valuation methods below)
2. Compare to current market price
3. If price < 67% of intrinsic value → potential buy
4. If price > intrinsic value → hold or sell

**IDX caveat:** Intrinsic value is harder to estimate when financial statements are unreliable.
Apply a *wider* margin of safety (40–50% discount) to account for reporting risk.

---

### 4. Defensive vs. Enterprising Investor (Chapters 4–7)

#### Defensive Investor (passive, low-effort, safety-first)
Criteria for stock selection:
- Adequate size: Revenue > IDR 500B equivalent (adapt to market)
- Strong financial condition: Current ratio ≥ 2x, long-term debt < net current assets
- Earnings stability: No deficit in past 10 years
- Dividend record: Uninterrupted dividends for 20+ years (IDX: at least 5–7 years consistently)
- Earnings growth: EPS growth ≥ 33% over past 10 years
- Moderate P/E: ≤ 15x average earnings (last 3 years)
- Moderate P/B: ≤ 1.5x book value
- Combined multiplier: P/E × P/B ≤ 22.5

**Portfolio allocation:**
- 50% bonds / 50% stocks (rebalance when market moves ±5%)
- Minimum 25% bonds even in bull markets
- IDX equivalent: consider SBN (government bonds), deposito, or money market funds as bond proxy

#### Enterprising Investor (active, research-intensive)
Additional strategies:
- Net-nets: Buy stocks trading below Net Current Asset Value (NCAV)
  - NCAV = Current Assets − Total Liabilities
  - Buy if price < 67% of NCAV per share
- Special situations: spinoffs, liquidations, arbitrage
- Bargain issues: P/E ≤ 10x, P/B ≤ 1x, positive earnings, decent balance sheet

---

### 5. Valuation Methods

#### Graham Number (quick screen)
```
Graham Number = √(22.5 × EPS × BVPS)
```
- EPS = Earnings Per Share (use average of last 3 years)
- BVPS = Book Value Per Share
- Buy if market price < Graham Number

**Example (IDX stock):**
- EPS avg = IDR 200
- BVPS = IDR 1,500
- Graham Number = √(22.5 × 200 × 1,500) = √6,750,000 ≈ IDR 2,598
- If stock trades at IDR 1,800 → trading at 69% of Graham Number → potential margin of safety

#### NCAV Screen (net-net, deep value)
```
NCAV per share = (Current Assets − Total Liabilities) / Shares Outstanding
```
Buy threshold: Price < 67% of NCAV per share

#### Earnings Power Value (EPV) — simplified
```
EPV = Normalized EBIT × (1 − tax rate) / WACC
```
Use when balance sheet is less meaningful (service/tech businesses)

---

### 6. Analyzing Financial Statements — Graham's Red Flags

Always check these before applying any valuation:

| Red Flag | What to Look For |
|---|---|
| Earnings manipulation | Large gap between net income and operating cash flow |
| Goodwill abuse | Goodwill > 20% of total assets (acquisition risk) |
| Related party transactions | Unusual RPT volumes vs. peers |
| Debt trend | Debt-to-equity rising YoY without revenue justification |
| Inventory buildup | Inventory growth > Revenue growth |
| Receivables inflation | AR days increasing significantly |
| Dilution | Share count rising without corresponding capital use |

**IDX-specific:** Check OJK filings and KSEI ownership data alongside financials. Governance
quality matters more on IDX than developed markets.

---

### 7. Market Behavior Interpretation

Use this framework when evaluating market conditions:

| Market Signal | Graham's Interpretation | Action |
|---|---|---|
| P/E of index > 20x | Overvalued, speculative territory | Shift to 75% bonds, reduce equity |
| P/E of index 10–20x | Normal range | Maintain 50/50 balance |
| P/E of index < 10x | Undervalued, opportunity zone | Shift to 75% equity |
| Stock drops 50% | Mr. Market is pessimistic | Re-evaluate fundamentals; may be opportunity |
| Stock rises 100% | Mr. Market is euphoric | Re-evaluate; may be time to sell |

**IDX IHSG P/E context:** Check current IHSG P/E vs historical average (~14–16x) to gauge
broad market valuation.

---

## Workflow: Analyzing a Stock Using Graham Framework

When user provides a stock ticker or company name, follow this sequence:

**Step 1 — Identify investor type**
Ask or infer: Is this user a defensive or enterprising investor?
This determines which criteria and effort level to apply.

**Step 2 — Collect key data**
Minimum needed:
- Last 3–5 years EPS (preferably 10 years)
- Current BVPS
- Current P/E and P/B
- Current ratio and debt levels
- Dividend history
- Operating cash flow vs net income

**Step 3 — Apply screens**
- Run Graham Number calculation
- Run defensive criteria checklist (if applicable)
- Flag any financial red flags
- Check NCAV if enterprising investor looking for deep value

**Step 4 — Assess margin of safety**
- Compare price to Graham Number
- Compare price to NCAV (if applicable)
- State: buy / hold / avoid — and the discount/premium %

**Step 5 — Apply IDX context adjustments**
- Widen margin of safety if reporting quality is uncertain
- Note any governance concerns
- Check if dividend is consistent and cash-backed

**Step 6 — State conclusion clearly**
Format:
```
Stock: [Ticker]
Graham Number: IDR X
Current Price: IDR Y
Discount/Premium: Z%
Verdict: [BUY / HOLD / AVOID]
Key Risk: [one sentence]
```

---

## Common Graham Quotes for Context

- *"The stock investor is neither right nor wrong because others agreed or disagreed with him; he is right because his facts and analysis are right."*
- *"The investor's chief problem — and even his worst enemy — is likely to be himself."*
- *"Price is what you pay. Value is what you get."* (attributed, consistent with Graham's framework)
- *"In the short run, the market is a voting machine. In the long run, it is a weighing machine."*

---

## IDX-Specific Adaptations Summary

| Graham Principle | IDX Adaptation |
|---|---|
| Reliable financials | Verify with cash flow; distrust earnings alone |
| 20-year dividend history | Lower bar: 5–7 consistent years |
| Large-cap focus | Apply extra discount to mid/small caps for liquidity risk |
| 33% margin of safety | Widen to 40–50% for governance uncertainty |
| Bond allocation | Use SBN, ORI, deposito, or money market funds |
| NCAV screens | Useful but check asset quality (land values, receivables age) |

---

## References

- *The Intelligent Investor* by Benjamin Graham (1973 revised edition, with Jason Zweig commentary)
- Key chapters: 1 (Investment vs Speculation), 8 (Mr. Market), 14–15 (Stock selection), 20 (Margin of Safety)
- Damodaran's valuation tools: https://pages.stern.nyu.edu/~adamodar/
- IDX financial data: https://www.idx.co.id, https://stockbit.com, https://sectors.app
