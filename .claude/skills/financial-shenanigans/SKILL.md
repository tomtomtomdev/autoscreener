---
name: financial-shenanigans
description: Detect accounting gimmicks, earnings manipulation, and aggressive financial reporting using Howard Schilit's "Financial Shenanigans" framework. Use this skill whenever the user wants to assess the quality of a company's earnings, audit or vet financial statements, screen for accounting red flags or fraud risk, evaluate whether reported numbers can be trusted, analyze a 10-K/10-Q/annual report for manipulation, investigate a suspicious revenue, cash flow, or margin trend, or run forensic-accounting due diligence before an investment. Trigger this even when the user just says "does this company's numbers look right," "is this earnings real," "check the quality of earnings," "any red flags in this filing," or pastes financial statement figures and asks what to make of them. Acts as the quality-of-earnings filter that should run before trusting numbers fed into value or growth screens.
---

# Financial Shenanigans

A forensic-accounting skill based on Howard Schilit, Jeremy Perler, and Yoni Engelhart's *Financial Shenanigans* (4th ed.). The goal: spot the tricks management uses to make a company look healthier than it is, **before** those numbers drive an investment decision.

Schilit's core insight is that fraud and aggressive accounting almost always leave a trail in the relationships *between* numbers — earnings drifting away from cash flow, receivables growing faster than sales, reserves quietly shrinking, one-time gains dressed up as recurring. You rarely need insider information; you need to know where to look and which numbers should move together.

## The three families of shenanigans

Schilit groups every gimmick into three families. This skill routes to a dedicated reference for each.

1. **Earnings Manipulation (EM)** — making profit look bigger or smoother than reality. Seven techniques, from booking revenue too early to stashing expenses on the balance sheet. → `references/earnings-manipulation.md`
2. **Cash Flow (CF)** — dressing up operating cash flow, the number investors trust *because* it's supposedly hard to fake. Four techniques. → `references/cash-flow-shenanigans.md`
3. **Key Metric (KM)** — gaming the non-GAAP and operational metrics (and balance-sheet ratios) that frame the story. Two techniques. → `references/key-metric-shenanigans.md`

A consolidated screening checklist and every forensic ratio with its formula lives in `references/forensic-checklist.md`. Read it when you need to actually compute the red-flag metrics or run a full screen.

## When to read the references

Read the relevant reference file(s) whenever you move past a high-level answer into actual analysis:
- The user names a specific symptom (e.g., "receivables are spiking") → read the family that owns it (EM for receivables).
- The user hands you statements or filings to vet → read `forensic-checklist.md` first, compute the ratios, then dive into whichever family the anomalies point to.
- The user wants the full treatment → read all four references.

Don't try to recite the techniques from memory for a real analysis. The references carry the detection cues, the formulas, and the classic case studies (Enron, WorldCom, Sunbeam, Lucent, Symbol, Computer Associates, Krispy Kreme, etc.) that make each pattern recognizable.

## The detection workflow

Follow this sequence when vetting a company. It mirrors how a forensic analyst actually works: look for divergences first, then form hypotheses, then confirm in the footnotes.

### 1. Establish what "normal" looks like
You need a baseline before an anomaly means anything. Pull at least 3–5 years (or 8+ quarters) of the income statement, balance sheet, and cash flow statement. Note the business model — a software company deferring revenue behaves nothing like a retailer. Compare against close competitors where possible; an industry-wide trend is context, a company-specific one is a flag.

### 2. Hunt for divergences (the cheap, high-yield scan)
Most shenanigans show up as two numbers that *should* track each other pulling apart. Compute these first (formulas in `forensic-checklist.md`):
- **Net income vs. cash flow from operations** — the single most important check. Earnings rising while operating cash flow stagnates or falls is the canonical warning sign.
- **Revenue growth vs. receivables growth (and DSO trend)** — receivables outrunning sales suggests revenue pulled forward or stuffed into the channel.
- **Revenue/COGS vs. inventory growth (and DSI trend)** — inventory building faster than sales suggests demand softening or costs being parked on the balance sheet.
- **Operating cash flow vs. free cash flow** — a wide, widening gap can mean capex is propping up the business or cash is being shuffled between statement sections.
- **Reserves and allowances as a % of the related asset** — quietly shrinking reserves (doubtful accounts, warranty, inventory) borrow from future earnings.

### 3. Form hypotheses, then route to the family
Each divergence points to a family. Spiking DSO → EM #1/#2 (revenue). Operating cash flow flattered by stretching payables or selling receivables → CF. A heroic non-GAAP "adjusted EBITDA" that strips out recurring costs → KM. Open the relevant reference and walk its detection cues.

### 4. Confirm in the footnotes and MD&A
This is where shenanigans are buried *and* disclosed — accounting-policy changes, revenue-recognition language, "change in estimate," reclassifications between statement sections, related-party transactions, acquisition accounting, and the gap between GAAP and the metrics management chooses to headline. A change in an accounting estimate or policy that conveniently lands right at a period when results would otherwise miss is itself a flag.

### 5. Weigh motive and opportunity
Shenanigans cluster where pressure and opportunity meet: a looming debt covenant, an acquisition currency to protect, management comp tied to a metric, a recent IPO/SPAC lock-up, a serial acquirer that can hide organic weakness in M&A noise, a dominant CEO/CFO with weak board oversight, or a recent auditor change. Note these as risk amplifiers, not proof.

## How to present findings

ALWAYS structure a forensic assessment like this:

```
# Quality-of-Earnings Assessment: [Company, period]

## Verdict
[One-line call: Clean / Watch / Significant concerns / Avoid — plus a confidence note]

## Red flags found
[For each: the shenanigan (family + number), the evidence (specific numbers/ratios
and where you found them), and why it matters. Cite the line items.]

## Divergence scorecard
[The key paired metrics from step 2, with values across periods and the trend.]

## Mitigating context
[Industry norms, legitimate business reasons, disclosures that explain the anomaly.]

## What to check next
[Specific footnotes, filings, or data the user should pull to confirm or clear each flag.]
```

## Guardrails that keep this honest

- **Aggressive ≠ fraudulent ≠ illegal.** Most shenanigans are choices within GAAP's gray zones. Frame findings as *quality-of-earnings risk* and *questions to investigate*, not accusations. Say "this is consistent with revenue being pulled forward; here's what would confirm or clear it," never "the company committed fraud."
- **One flag is a question; a pattern is a thesis.** A single elevated ratio often has a benign explanation. Conviction should come from several independent flags pointing the same direction, ideally across families (e.g., revenue *and* cash flow *and* a flattering metric all telling the same story).
- **Context dominates.** Seasonality, a genuine business-model shift, an acquisition, or an industry-wide swing can mimic every one of these patterns. Always check whether peers show the same thing.
- **You are not giving investment advice.** This skill assesses earnings quality. The user makes the call. Note that you're not a financial advisor when a conclusion edges toward "buy/sell."
- **Data limits the verdict.** If you only have summary figures, say what you can't see (footnotes, segment detail, statement-of-cash-flows breakdown) and how that caps your confidence.
