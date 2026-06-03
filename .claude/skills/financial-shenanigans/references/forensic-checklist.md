# Forensic Checklist, Formulas & Decision Tree

The working toolkit. Use this to actually compute the red-flag metrics and run a full screen. Every formula maps back to one or more shenanigans (EM / CF / KM); the mapping is noted so a flag routes you straight to the right reference.

Conventions: use **average** balance-sheet figures `(beginning + ending) / 2` for ratios that pair an income/flow item with a balance item, when you have both period-end balances. `Days` = 365 for annual, 91 for quarterly (or actual days in period).

---

## 1. The forensic ratio library

### Revenue-quality (point to EM1, EM2, KM2)
- **Days Sales Outstanding (DSO)** = (Accounts Receivable / Revenue) × Days
  Rising DSO → revenue recognized ahead of collection, channel stuffing, or bogus revenue.
- **Receivables growth vs. revenue growth** = %Δ AR − %Δ Revenue
  Positive and widening → revenue outrunning real demand. The single best revenue flag.
- **Unbilled receivables / total receivables** — rising → aggressive long-term-contract or pre-billing recognition.
- **Deferred revenue trend** (and deferred revenue / revenue) — falling deferred revenue while revenue rises → pulling future revenue forward.

### Cost & margin quality (point to EM4, EM5, EM7)
- **Days Sales of Inventory (DSI)** = (Inventory / COGS) × Days
  Rising DSI → demand softening, or costs parked in inventory rather than expensed.
- **Inventory growth vs. revenue/COGS growth** — inventory outpacing sales → obsolescence/write-down risk being deferred.
- **Gross margin trend** — unexplained expansion can signal under-costing, capitalized costs, or reserve releases; check against peers.
- **Depreciation expense / gross PP&E** — falling → useful lives extended or method changed to defer expense (EM4).
- **Capitalized costs / revenue** (capitalized software, deferred customer-acquisition cost, "other assets") — rising → operating costs being capitalized (EM4 / CF2).

### Reserve & accrual quality (point to EM5, EM6, EM7)
- **Allowance for doubtful accounts / gross receivables** — falling while receivables/aging rise → under-reserving.
- **Warranty reserve / sales**, **inventory reserve / inventory** — falling → cookie-jar release or under-accrual.
- **Accruals ratio (balance-sheet)** = (ΔNet operating assets) / average net operating assets, where Net operating assets ≈ (Total assets − cash) − (Total liabilities − total debt). High accruals → earnings driven by accounting estimates, not cash (Sloan accrual anomaly; complements Schilit).
- **Total accruals (cash-flow basis)** = Net income − CFO. Large and growing positive → earnings not backed by cash.

### Cash-flow quality (point to CF1–CF4)
- **CFO vs. Net income** — track the ratio CFO / NI and the absolute gap over time. NI rising while CFO lags is the master warning sign.
- **Free cash flow (FCF)** = CFO − Capex. **CFO − FCF gap** widening → capex-dependent or costs shifted to investing (CF2).
- **Capex / revenue** and **capex / depreciation** — rising capex/depreciation > 1 sustained → either growth investment or capitalized opex (CF2); judge with context.
- **Days Payable Outstanding (DPO)** = (Accounts Payable / COGS) × Days
  Rising DPO → stretching suppliers to flatter CFO (CF4 / KM2).
- **Cash conversion / cash-flow cycle** = DSO + DSI − DPO — sudden improvement via DPO/DSO timing rather than operations → unsustainable CFO (CF4).
- **CFO inclusive of acquisitions** — normalize by removing acquired-entity contributions to find organic CFO (CF3).

### Metric & leverage quality (point to KM1, KM2)
- **GAAP NI vs. adjusted/non-GAAP NI** — track the gap and the nature of add-backs; recurring "one-timers" and add-back of stock comp are tells.
- **True leverage** = (Reported debt + supplier-financing/reverse-factoring + capitalized off-balance-sheet obligations) / EBITDA — vs. reported leverage; gap → hidden obligations (KM2).
- **Metric definition stability** — qualitative: did "active users," "bookings," "same-store sales," or the non-GAAP adjustment list change basis? (KM1)

---

## 2. The screening checklist

Run top to bottom. Each "yes" is a flag to route and investigate, not a verdict.

**Revenue**
- [ ] Is DSO rising over the last several periods?
- [ ] Are receivables growing faster than revenue?
- [ ] Is deferred revenue falling while revenue rises?
- [ ] Did revenue-recognition policy or delivery/acceptance terms change?
- [ ] Any new, vaguely defined revenue line, or related-party revenue?

**Expenses / margins**
- [ ] Is DSI rising, or inventory outpacing sales?
- [ ] Are capitalized costs / "other assets" growing faster than revenue?
- [ ] Did depreciation/amortization rates, useful lives, or methods change to lower expense?
- [ ] Did gross or operating margin expand without an operational explanation?

**Reserves / accruals**
- [ ] Are allowance/reserve ratios (doubtful accounts, warranty, inventory) falling?
- [ ] Is the accruals ratio (NI − CFO, or balance-sheet accruals) large and growing?
- [ ] Any "change in estimate" reducing an accrual right when results would otherwise miss?
- [ ] A large restructuring/impairment charge — followed by reversals or unusually high later margins?

**Cash flow**
- [ ] Is NI rising while CFO stagnates or falls?
- [ ] Is the CFO − FCF gap widening?
- [ ] Is DPO rising (stretching payables) or DSO falling via factoring?
- [ ] Did CFO jump alongside an acquisition (CF3) or a one-time working-capital squeeze (CF4)?
- [ ] Any "sale of receivables," securitization, factoring, or supplier-financing disclosure?

**Metrics / leverage / governance**
- [ ] Is the GAAP-vs-non-GAAP gap widening, with recurring add-backs?
- [ ] Did any headline metric's definition change?
- [ ] Does economic leverage exceed reported leverage (off-balance-sheet, reverse factoring)?
- [ ] Motive/opportunity present — covenant pressure, comp tied to a metric, dominant CEO/CFO, weak board, recent auditor change, serial acquirer, recent IPO/SPAC?

---

## 3. Detection decision tree

```
START: What's the symptom?
│
├─ Earnings up but cash flow not keeping up?
│   ├─ Receivables/DSO rising? .................... EM1 / EM2 (revenue)
│   ├─ Inventory/DSI rising? ...................... EM4 / EM5 (deferred cost / write-down risk)
│   ├─ Capitalized costs/"other assets" rising? ... EM4 (+ CF2 mirror)
│   └─ Reserves/allowances falling? .............. EM5 / EM7 (cookie-jar)
│
├─ Cash flow from operations looks "too good"?
│   ├─ Coincides with new debt / factoring? ....... CF1
│   ├─ Capex rising, CFO−FCF gap widening? ........ CF2
│   ├─ Coincides with an acquisition? ............. CF3
│   └─ DPO up / DSI down / DSO down by timing? .... CF4 (unsustainable)
│
├─ One-time gain or income spike?
│   ├─ Gain inside operating income? .............. EM3
│   └─ Reserve released into earnings? ............ EM3 / EM5
│
├─ Smooth-as-glass earnings / suspicious timing?
│   ├─ Income hidden in a good period? ............ EM6
│   └─ Big-bath charge in a bad period? .......... EM7
│
└─ The story leans on a non-GAAP metric?
    ├─ Adjusted number diverging from GAAP? ....... KM1
    ├─ A metric's definition changed? ............. KM1
    └─ Balance-sheet/leverage ratios suspiciously
       stable or hugging covenants? .............. KM2
```

When a branch lights up, open the matching reference file (`earnings-manipulation.md`, `cash-flow-shenanigans.md`, or `key-metric-shenanigans.md`) and walk its detection cues before concluding.

---

## 4. Scoring guidance (how many flags = how much worry)

There's no official Schilit score, but a useful discipline:
- **0–1 isolated flag with a plausible benign explanation → "Clean / Watch."** Note it; don't over-read.
- **2–3 flags within one family → "Watch."** Could be one underlying issue (e.g., aggressive revenue timing). Investigate the footnotes.
- **Flags across two or more families pointing the same direction → "Significant concerns."** This is the high-conviction pattern: e.g., revenue pulled forward (EM) *and* CFO flattered by factoring (CF) *and* a metric redefined to mask it (KM).
- **A documented motive (covenant/comp/IPO) plus a multi-family pattern → "Avoid / deep due diligence required."**

Always pair the score with *what would clear it* — the specific footnote, segment detail, or subsequent-period data that would confirm or dismiss each flag. The output is an investigation map, not a verdict.

---

## 5. Where to find each clue in the filings
- **Income statement** — margin trends, "other income," gains in operating lines, depreciation/amortization.
- **Balance sheet** — receivables, inventory, capitalized/"other" assets, reserves, payables, debt.
- **Statement of cash flows** — the NI→CFO reconciliation, capex (investing), borrowings/receivable sales (financing); this is where section-shifting (CF family) is exposed.
- **Footnotes** — revenue-recognition policy, accounting-estimate/policy changes, reserves and allowances, securitization/factoring/supplier financing, leases and off-balance-sheet items, related parties, acquisition accounting, segment detail.
- **MD&A** — management's framing, the non-GAAP reconciliation, metric definitions, covenant discussion.
- **Proxy / 8-K** — comp metrics, auditor changes, restatements, CFO/CEO turnover.
