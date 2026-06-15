---
name: quality-of-earnings
description: Forensic earnings-quality analysis using Thornton O'Glove's "Quality of Earnings" methodology. Use this whenever the user wants to judge whether a company's reported profits are real, sustainable, and cash-backed — or inflated by accounting choices. Triggers include analyzing a 10-K/10-Q/annual report, vetting a stock's earnings, spotting accounting red flags, comparing reported EPS to "core" earnings, checking receivables/inventory/depreciation/tax/cash-flow quality, or any request like "are these earnings real?", "is this company cooking the books?", "what's the quality of earnings here?", or "find the red flags in these financials." Use it even when the user just pastes financial statements and asks what to make of them.
---

# Quality of Earnings (O'Glove)

Thornton O'Glove's core thesis: **reported earnings are an opinion; cash is a fact.** Two companies with identical reported EPS can have wildly different *real* earning power, depending on the accounting choices buried in the footnotes. This skill turns O'Glove's forensic techniques into a repeatable workflow for separating durable, cash-backed earnings from earnings propped up by accounting maneuvers, one-time gains, and borrowing-from-the-future.

The goal is never a buy/sell call. The goal is a **quality verdict**: how much should an investor trust the headline number, and what is the company *really* earning?

## When this applies

Use it whenever someone hands you financials (or links/pastes a 10-K, 10-Q, annual report, or earnings release) and wants to know whether the earnings are trustworthy. It pairs naturally with valuation/screening frameworks (Fisher's PSR, Lynch's PEG, Graham/Buffett quality filters): **run quality-of-earnings first** — a cheap-looking PEG built on phantom earnings is a trap, and this is the filter that catches it.

## Inputs you need

Ask for what's missing; degrade gracefully if some isn't available.

- **Income statement** — multi-year (3–5 yrs ideal), with line detail (COGS, SG&A, R&D, D&A, interest, "other income," tax).
- **Balance sheet** — multi-year, especially receivables, inventory (by category if available), PP&E, deferred taxes, debt.
- **Cash flow statement** — multi-year, especially operating cash flow and capex.
- **Footnotes + MD&A** — where the real story lives. Tax footnote, inventory method (LIFO/FIFO), depreciation policy, pension assumptions, segment data, "nonrecurring" disclosures.
- **The shareholders' letter** — and prior years' letters, if doing the qualitative read.

Single-period data still allows ratio checks; **trends are where the signal is**, so push for multiple years.

## Core principle: cross-check the story against the numbers

O'Glove's whole method is *triangulation*. Management narrates a story (the letter, the press release, MD&A). The audited statements and footnotes constrain it. **Discrepancies between the optimistic narrative and the conservative footnote are the single richest source of red flags.** Always read the footnotes; never trust the headline EPS or the CEO letter alone.

## Workflow

1. **Establish the headline.** Note reported net income / EPS and the growth rate management is selling.
2. **Run the eight lenses** (below). Each yields a flag: 🟢 clean / 🟡 watch / 🔴 red. See `references/lenses.md` for the full method on each.
3. **Compute adjusted ("core") earnings.** Strip out nonrecurring/nonoperating items and reverse obvious accounting boosts to estimate sustainable earning power. Formulas in `references/formulas.md`.
4. **Score and synthesize** into an earnings-quality verdict using the template in `references/report-template.md`.
5. **State confidence and gaps.** Be explicit about what you couldn't verify (e.g., footnotes not provided).

## The eight lenses

Each lens detects a specific way earnings can mislead. Brief version here; full procedure, thresholds, and worked logic in `references/lenses.md`, with every formula collected in `references/formulas.md`.

1. **Nonrecurring & nonoperating income.** Asset sales, litigation settlements, one-time tax benefits, gains on debt retirement, pension income, accounting-change gains. These inflate "earnings" but won't repeat. → Strip them out to find core operating earnings. *Red flag: growth that depends on one-time items.*

2. **Accounts receivable vs. sales.** Receivables should grow roughly in line with sales. Receivables (or days-sales-outstanding) growing materially faster signals channel-stuffing, aggressive revenue recognition, weakening collections, or distressed customers — often a precursor to a sales air-pocket or write-off. *Compare AR growth % to sales growth %; watch DSO trend.*

3. **Inventory vs. sales.** Same logic: inventory outgrowing sales signals overproduction, obsolescence risk, and looming write-downs or margin cuts. Rising **finished-goods** inventory is the worst signal. Also check LIFO/FIFO and watch for **LIFO liquidations** (a non-repeatable earnings boost). *Watch inventory growth %, turnover, and category mix.*

4. **Depreciation & amortization.** Watch for changes that *reduce* the expense without economic basis: extending useful lives, switching accelerated→straight-line, raising salvage values, slowing write-offs. These borrow earnings from the future. *Compare D&A to capex; flag method/life changes in footnotes.*

5. **Discretionary "future-directed" costs.** R&D, advertising, maintenance, marketing. Cutting these flatters this quarter at the expense of future competitiveness. *Track each as % of sales over time; a sudden cut into an earnings "beat" is low quality.*

6. **Taxes.** A falling effective tax rate can manufacture EPS growth. Distinguish sustainable rate changes from one-time benefits (NOL carryforwards, credits, settlements). A widening gap between book income and taxable income (rising deferred tax liabilities) signals aggressive book accounting. *Compare effective vs. statutory rate; track deferred taxes.*

7. **Cash flow vs. earnings.** The master check. If net income rises while operating cash flow stalls or falls, the earnings are likely low quality. *Track the accrual ratio and OCF/Net Income; reconcile the gap to AR, inventory, and accruals.*

8. **Hidden liabilities & off-statement risk.** Pension/OPEB assumptions (aggressive return or discount-rate assumptions inflate income), capitalized-vs-expensed costs, reserve releases ("cookie-jar" reserves), operating leases/other off-balance-sheet obligations, and shareholder-letter omissions. *Footnote-driven; flag anything that moves expense off the income statement.*

## A few rules that keep the analysis honest

- **Direction and persistence matter more than a single ratio.** One year of receivables outpacing sales is a yellow flag; three years is a red one. Note the trend, not just the level.
- **Context the divergence.** A faster-growing AR balance can be benign (a deliberate move into a new market on credit terms, an acquisition mid-year, a seasonal quarter-end). Name the benign explanation and say what would distinguish it from the malign one — don't cry fraud on one ratio.
- **Quote the footnote.** When a flag rests on an accounting choice (a useful-life extension, a LIFO liquidation, a pension assumption), cite the specific disclosure. If you don't have it, say the flag is unconfirmed.
- **Adjusted EPS is an estimate, not a precise figure.** Show your adjustments line by line so the user can challenge them.

## Output

Produce the earnings-quality report per `references/report-template.md`: headline vs. adjusted earnings, the eight-lens scorecard, the most important 2–4 flags explained, an overall quality rating (High / Medium / Low), and an explicit list of caveats and missing data.

**This is analytical, not advisory.** The output describes earnings quality and accounting risk; it is not a recommendation to buy, sell, or hold, and you are not a financial advisor. If the user asks "should I buy it," give the quality read and let them combine it with valuation and their own judgment.
