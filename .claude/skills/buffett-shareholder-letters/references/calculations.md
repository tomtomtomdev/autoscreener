# Calculations & Formulas

Each formula below is paired with its source idea in the letters and a worked example.
Treat every estimated input (especially maintenance capex and future growth) as a
judgment, and carry it through as a *range*, not a point.

## Table of contents
1. Owner Earnings
2. Look-through Earnings
3. The One-Dollar Retained-Earnings Test
4. Returns on Tangible Capital & Economic Goodwill
5. Insurance Float & the Cost of Float
6. Intrinsic Value via Discounted Owner Earnings
7. Margin of Safety sizing

---

## 1. Owner Earnings

The measure Buffett prefers over GAAP earnings (1986 letter, appendix on the purchase of
Scott Fetzer). It is the cash a business throws off that an owner could pocket without
impairing the business's competitive position or unit volume.

```
Owner Earnings = (a) Reported earnings
               + (b) Depreciation, depletion, amortization, and other non-cash charges
               − (c) Average annual maintenance capex required to fully maintain
                     long-term competitive position and unit volume
               − (d) Any additional working capital required to maintain unit volume
```

Key cautions Buffett himself raises:
- Item (c) is a *guess*, often the hardest and most important number. Distinguish
  **maintenance** capex (keep the business where it is) from **growth** capex (expand it).
  Only maintenance capex belongs here.
- Because (c) must be estimated, owner earnings cannot be computed to the penny — which is
  exactly why he prefers being approximately right over precisely wrong.
- GAAP earnings + D&A − *total* reported capex (i.e. treating all capex as maintenance) is
  a conservative shortcut, but it understates owner earnings for genuinely growing firms.

**Worked example.** Reported net income $500M; D&A $120M; total capex $200M, of which you
estimate $90M is maintenance and $110M is growth; incremental working capital to hold unit
volume $10M.

```
Owner Earnings = 500 + 120 − 90 − 10 = $520M
```

If you couldn't separate maintenance from growth capex, the conservative figure would be
500 + 120 − 200 = $420M. Report the range $420M–$520M and state which capex split drives it.

---

## 2. Look-through Earnings

Reported earnings count only *dividends* received from minority stock holdings, which
understates Berkshire's true economic earnings because retained earnings of investees also
work for shareholders (1980s letters; formalized over time).

```
Look-through Earnings = Reported operating earnings
                      + Berkshire's share of undistributed (retained) earnings of investees
                      − Incremental tax that would be due if those retained earnings
                        had instead been paid out as dividends
```

Use this when valuing a holding company or any investor whose reported earnings exclude the
retained profits of partially-owned businesses. The point: economic earning power ≠ the
dividend line.

**Worked example.** Operating earnings $1,000M; share of investees' retained earnings
$300M; incremental tax if distributed at, say, ~14% effective on inter-corporate
dividends ≈ $42M.

```
Look-through Earnings = 1,000 + 300 − 42 = $1,258M
```

---

## 3. The One-Dollar Retained-Earnings Test

Buffett's "unrestricted earnings" test (1983 onward): retaining earnings is justified only
if it produces value.

> For every dollar retained, the company should create at least one dollar of market value.

Measure over **rolling ~5-year periods** to smooth out market noise:

```
Value created per retained dollar
  = (Increase in market value over period) ÷ (Cumulative retained earnings over period)

Pass if the ratio ≥ 1.0
```

**Worked example.** Over 5 years a company retained a cumulative $4.0B and its market value
rose by $9.2B.

```
Ratio = 9.2 / 4.0 = 2.3  → comfortably passes; retention is creating value.
```

A ratio persistently below 1.0 is a red flag on capital allocation: the company would
serve owners better by paying out or buying back stock below intrinsic value.

---

## 4. Returns on Tangible Capital & Economic Goodwill

A franchise reveals itself as **high returns on modest tangible capital** (1983 See's
Candies appendix). Distinguish:

- **Accounting goodwill** — the premium over net tangible assets recorded at acquisition;
  historically amortized down over time. It tells you little about the business.
- **Economic goodwill** — the business's ability to earn returns *far above market rates*
  on its tangible assets. Unlike accounting goodwill, real economic goodwill tends to
  *grow*, and a franchise that needs little tangible capital to grow is especially valuable
  in inflation (its earnings rise without a proportionate cash reinvestment).

```
Pretax Return on Net Tangible Assets
  = Pretax operating earnings ÷ (Net working capital + Net plant & equipment)
```

**Worked example (See's-style).** A candy business earns $80M pretax on $40M of net
tangible assets → 200% pretax return on tangible capital. A commodity manufacturer earning
$80M might need $700M of tangible assets → ~11%. The first carries enormous economic
goodwill; the second essentially none. The first is worth a large premium to book; the
second is worth roughly its tangible assets.

Inflation test: if the business can grow unit volume and raise prices *without*
proportionately growing its tangible asset base, its economic goodwill compounds in real
terms — the hallmark of a See's-type franchise.

---

## 5. Insurance Float & the Cost of Float

Float is money Berkshire holds but does not own — premiums collected before claims are
paid — and can invest in the interim. Its value depends on its **size** and its **cost**.

```
Cost of Float = Underwriting loss ÷ Average float for the period

  • Underwriting profit  → NEGATIVE cost of float (you are paid to hold investable money)
  • Underwriting loss    → positive cost; compare it to the risk-free rate
```

Float is attractive only if its cost is below what you'd pay to borrow, and best when its
cost is negative *and* it is durable or growing. Underwriting discipline — writing less
business when prices are bad (the "Noah principle": predicting rain doesn't count, building
arks does, 2001 letter) — is what keeps the cost low.

**Worked example.** Average float $80B; underwriting profit $1.6B.

```
Cost of Float = −1,600 / 80,000 = −2.0%  → Berkshire is effectively paid 2% to use $80B.
```

---

## 6. Intrinsic Value via Discounted Owner Earnings

Intrinsic value = the discounted value of cash that can be taken out over the business's
remaining life (1994). Implement as a two-stage discounted **owner-earnings** model.

```
Stage 1 (explicit forecast, years 1..N):
  PV_explicit = Σ  OE_t / (1 + r)^t

Stage 2 (terminal value at year N):
  Terminal Value = OE_(N+1) / (r − g)         [Gordon growth; require g < r]
  PV_terminal    = Terminal Value / (1 + r)^N

Intrinsic Value (equity) = PV_explicit + PV_terminal − net debt (+ excess cash / non-op assets)
Per share = Intrinsic Value ÷ shares outstanding
```

Where:
- `OE_t` = projected owner earnings in year t.
- `r` = discount rate. Buffett anchors to the long-term government bond yield rather than a
  beta-derived rate; he takes his margin in the *price*, not by padding `r`.
- `g` = perpetual growth rate, conservative and below `r`; for most businesses keep it at or
  below long-run nominal GDP.

**Worked example.** OE next year $520M, growing 8%/yr for 10 years, then 3% forever;
`r` = 5% (≈ long bond); net debt $1.0B; 200M shares.

- Discount each of years 1–10 of growing owner earnings at 5%.
- Year-10 OE ≈ $520M × 1.08^9 ≈ $1,040M; year-11 ≈ $1,071M.
- Terminal value = 1,071 / (0.05 − 0.03) = $53.6B; discounted back 10 years at 5% ≈ $32.9B.
- PV of years 1–10 owner earnings ≈ $6.5B.
- Intrinsic equity value ≈ 6.5 + 32.9 − 1.0 = $38.4B → ~$192/share.

Always run a low/base/high set of assumptions and present the **range**. If the answer
flips from cheap to expensive on plausible assumption changes, that itself is the finding:
the business is too hard to value with confidence — stay inside the circle of competence.

---

## 7. Margin of Safety Sizing

There is no fixed percentage in the letters; the discount you demand scales with your
uncertainty.

```
Required discount to intrinsic value increases with:
  • lower certainty about long-term economics (weaker/narrower moat)
  • lower certainty about management
  • higher sensitivity of the valuation to assumptions

Heuristic: wide-moat, highly predictable franchise  → smaller margin may suffice
           narrower moat or assumption-sensitive value → demand a wide margin, or pass
```

The discipline: act only when price < intrinsic-value range by enough that you would still
be fine if your central estimate proved optimistic.
