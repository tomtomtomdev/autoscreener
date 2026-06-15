---
name: graham-financial-statements
description: >-
  Read and interpret a company's financial statements using Benjamin Graham's
  method from "The Interpretation of Financial Statements" (1937). Use this
  skill whenever the user wants to analyze, interpret, or sanity-check a balance
  sheet, income statement (income account), or cash position; compute or explain
  financial ratios (current ratio, quick/acid-test ratio, working capital,
  net-net working capital, times-interest-earned/fixed-charge coverage, book
  value, margins, return on invested capital); assess the financial strength,
  liquidity, or solvency of a company; evaluate bond or preferred-stock safety;
  or judge whether reported earnings and asset values are sound. Trigger this
  even when the user just pastes statement figures and asks "is this company
  healthy?", "what do these numbers mean?", or "is this stock cheap on the
  assets?"—and even when they don't name Graham explicitly. Pairs with value and
  growth screening skills as the underlying statement-reading layer.
---

# Interpreting Financial Statements — Graham's Method

This skill applies the analytical framework from Benjamin Graham & Spencer
Meredith's *The Interpretation of Financial Statements* (1937). The book's thesis
is that financial statements are read not to admire the totals but to test a
company against a small set of **conservative quantitative standards** and to
judge the **quality and durability** behind the reported figures.

Graham's discipline rests on three habits, applied in order:

1. **Define every line before interpreting it.** Many errors come from treating
   "surplus," "reserves," "intangibles," or "net income" as self-explanatory.
2. **Convert raw figures into ratios**, because an absolute number is
   meaningless until set against another (assets vs. liabilities, earnings vs.
   charges, price vs. value).
3. **Apply margin-of-safety thresholds**, then ask whether the numbers are
   *real*—whether earnings are recurring and whether assets are worth their
   carrying value.

## When to read the reference files

Keep this file in context for the workflow, formulas, and thresholds. Read the
detailed glossaries only when you need precise definitions of individual line
items or are resolving an ambiguous figure:

- `references/balance-sheet.md` — every balance-sheet line item defined
  (current assets, fixed assets, intangibles, reserves, the capitalization
  structure, surplus), plus how Graham treats each in analysis.
- `references/income-account.md` — income-statement line items, the difference
  between operating and non-operating income, depreciation, the treatment of
  one-time items, and how to spot earnings that aren't durable.
- `references/ratios.md` — the full ratio catalogue with worked examples and
  Graham's industry-specific standards for bond and preferred-stock safety.

## Workflow

When given a set of financials (or asked to interpret a company), proceed in
this sequence. Don't skip step 1—Graham insists the analyst restate figures into
clean categories before computing anything.

### Step 1 — Lay out and classify the figures
Sort the balance sheet into **current assets, fixed/other assets, intangibles**;
**current liabilities, long-term debt**; and the **capitalization** (bonds,
preferred, common + surplus). Sort the income account into **sales → operating
income → fixed charges → pre-tax income → taxes → net income**, then per-share
figures. Flag anything you had to estimate or that the company buried.

### Step 2 — Test financial position (liquidity & solvency)
Compute the liquidity and capitalization ratios in the table below. This answers
"can the company pay its bills and survive a bad year?"

### Step 3 — Test the income account (earnings power & safety of charges)
Compute margins, coverage of fixed charges, and return on capital. This answers
"are the earnings adequate, durable, and safely above the company's obligations?"

### Step 4 — Test value (price vs. the statements)
Relate market price to earnings, to book/tangible book value, and—where
relevant—to net current asset value. This answers "what am I being asked to pay
for these numbers?"

### Step 5 — Judge quality, then conclude
Before stating a conclusion, ask Graham's quality questions (see checklist):
Are earnings recurring or padded by one-time gains? Are assets carried honestly
or inflated by intangibles and stale inventory? Are reserves real liabilities or
disguised surplus? State the conclusion as Graham would: a sober verdict on
strength and value, with the specific ratios that drive it, never a single
score divorced from the reasons.

## The core ratios, formulas, and Graham's standards

Use these as the working set. Full derivations and the per-industry coverage
standards are in `references/ratios.md`.

### Financial position
| Ratio | Formula | Graham's standard |
|---|---|---|
| Working capital | Current assets − current liabilities | Should be positive and ample; the cushion for operations |
| **Current ratio** | Current assets ÷ current liabilities | **≥ 2.0** for an industrial; lower is tolerable only for utilities/regulated firms |
| **Quick (acid-test) ratio** | (Cash + receivables) ÷ current liabilities | **≥ 1.0**; inventory excluded because it may not convert to cash quickly |
| Cash-asset ratio | (Cash + marketable securities) ÷ current liabilities | Higher is safer; very low cash with high current ratio = inventory-heavy |
| Inventory-to-receivables / turnover | Sales ÷ inventory; sales ÷ receivables | Watch for inventory or receivables growing faster than sales (stale goods, slow collection) |
| Debt position | Current assets ÷ total liabilities | Strongest firms have current assets well above **all** liabilities |
| Capitalization mix | Bonds ÷ total capital; pref ÷ total capital | Heavy senior leverage magnifies risk to the common; Graham favors common-heavy structures for industrials |

### Earnings power and safety of charges
| Ratio | Formula | Graham's standard |
|---|---|---|
| Operating margin | Operating income ÷ sales | Compare across years and to peers; stability matters more than a single high reading |
| Net margin | Net income ÷ sales | Same—look for consistency, not a one-year spike |
| **Times interest earned** (fixed-charge coverage) | Income available for charges ÷ fixed charges | See per-industry minimums below; use the **total-deductions method**, not prior-deductions |
| Times preferred dividends earned | Net income ÷ (interest + preferred dividends), inclusive basis | Coverage should comfortably exceed 1; thin coverage endangers the preferred |
| Return on invested capital | Net operating income ÷ (long-term debt + equity) | Durable, above-average returns signal real earning power |
| Earnings on common equity | Net income ÷ common equity | Trend and stability over a span of years, not one figure |

**Minimum average fixed-charge coverage (Graham's bond-safety standards):**
- Public utilities: **~2×** (some editions cite 1.75× minimum)
- Railroads: **~2.5×**
- Industrials: **~3×**

These are *minimum averages over a span of years*, not a single good year. A
bond/preferred that only clears the bar in boom years fails the test. Always
compute coverage by the **total- (cumulative-) deductions method**: divide total
income available by *all* prior charges combined. The "prior-deductions method"
(crediting senior issues with earnings before junior charges) flatters junior
securities and Graham rejects it as misleading.

### Value
| Measure | Formula | Graham's reading |
|---|---|---|
| Book value per share | Common equity ÷ shares | The accounting net worth behind a share |
| **Tangible book value** | (Common equity − intangibles) ÷ shares | Graham's preferred net-worth figure; **exclude goodwill, patents, trademarks** unless demonstrably worth their carrying value |
| Net current asset value ("net-net") | (Current assets − **total** liabilities) ÷ shares | A stock below this is backed by liquid assets alone—Graham's deep-value bargain test |
| Price/earnings ratio | Price ÷ EPS | Set the multiple against earnings stability and growth; a high P/E demands durable growth |
| Earnings yield | EPS ÷ price | The inverse view; compare to bond yields for relative attractiveness |

## Interpretation checklist

Run through these before concluding. Each maps to a Graham concern:

- [ ] **Liquidity:** Current ratio ≥ 2 and quick ratio ≥ 1? If not, why—and is it normal for the industry?
- [ ] **Solvency:** Are current assets greater than *all* liabilities? How heavy is senior (bond/preferred) capital?
- [ ] **Coverage:** Do fixed charges clear the industry minimum *as an average over several years*, by the total-deductions method?
- [ ] **Earnings durability:** Is net income recurring, or inflated by asset sales, tax credits, or non-operating gains? Strip one-time items.
- [ ] **Depreciation honesty:** Is depreciation adequate, or is the company under-charging it to flatter earnings?
- [ ] **Reserves:** Are "reserves" genuine liabilities, contingency cushions, or surplus in disguise? Reclassify accordingly.
- [ ] **Asset quality:** Are intangibles a material part of book value? Is inventory stale or receivables slow? Use tangible book value.
- [ ] **Surplus / dividends:** Has retained earnings (surplus) grown over time, and is the dividend covered by earnings?
- [ ] **Value:** What is price relative to earnings, tangible book, and net current asset value?
- [ ] **Consistency:** Do the figures tell the same story across *several years*? Graham trusts trends over single snapshots.

## Decision flow

```
Is the financial position sound?
  Current ratio ≥ 2  AND  quick ratio ≥ 1  AND  current assets > total liabilities?
    │
    ├─ NO  → Weak position. Acceptable only with strong industry justification
    │         (e.g., a regulated utility) or a deep asset discount. Otherwise
    │         flag solvency risk and stop being charitable about earnings.
    │
    └─ YES → Are earnings adequate and safe?
               Fixed charges covered ≥ industry minimum (avg over years) AND
               earnings recurring (not padded by one-time items)?
                 │
                 ├─ NO  → Earnings/charge risk. Senior securities may be unsafe;
                 │         the common is speculative on this basis.
                 │
                 └─ YES → Are the assets and earnings honestly stated?
                            Tangible book intact, depreciation adequate,
                            reserves real, inventory/receivables clean?
                              │
                              ├─ NO  → Discount the reported figures; recompute on
                              │         a conservative (tangible, restated) basis.
                              │
                              └─ YES → Sound company. Now judge VALUE:
                                        • Below net current asset value → deep bargain
                                        • Modest P/E + intact tangible book → value candidate
                                        • Rich P/E → requires durable growth to justify
```

## Output guidance

Present interpretations as Graham would: lead with the verdict on **financial
position**, then **earnings power and safety**, then **value**, each backed by
the specific ratios you computed and how they compare to his standards. Show the
formulas and the arithmetic so the reader can check the work. When figures are
missing, say what you'd need rather than guessing. Avoid a single composite
"score"—Graham's method is a structured judgment, and the reasons matter more
than any number. Note explicitly that the book's numeric thresholds (especially
the current-ratio and coverage minimums) date from the 1930s–40s industrial
economy; flag where a modern asset-light or regulated business legitimately
departs from them, and lean on the *reasoning* behind a standard rather than
applying it mechanically.
