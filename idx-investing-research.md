# Indonesia Market (IDX) — Investing & Analysis Research Notes

A consolidated reference on how to assess the Indonesian market, select stocks, and paper trade realistically, built around a value-investing lens. Companion to the installable skills (see Appendix).

> **Not financial advice.** This is methodology. Any specific figures should be checked against actual data; paper-trading results don't fully transfer to live trading because the psychological cost of real loss is removed.

---

## 1. Core principle

Treat the four data feeds as separate layers and only let them meet at the decision point. Each answers a different question, and most bad decisions come from using one layer to answer a question it can't.

| Layer | Question it answers | Used in |
|-------|--------------------|---------|
| Fundamentals (income statement, balance sheet, cash flow) | **What** to own | Bottom-up selection |
| Broker summary + foreign/domestic flow | **Who** is moving it | Top-down regime *and* bottom-up validation (see §2) |
| Charts (OHLCV) | **When** | Timing / entries |
| Index & sectoral data (IHSG, LQ45, sectoral) | **What regime** we're in | Top-down condition |

---

## 2. Data inventory — granularity matters

### Broker summary — **per individual stock**
Pulled for one ticker over a day or range. Lists which brokerage member firms were on the buy side vs. the sell side, with each broker's volume, value, and average price. Answers "who moved *this specific stock*." This is the "bandarmology" data. There is **no market-wide version** of broker summary — it is inherently per-stock. Use it bottom-up: once a name passes the fundamental screen, check whether credible brokers are accumulating rather than distributing.

### Foreign / domestic flow — **both levels**
- **Market-wide (aggregate):** net foreign buy/sell across the whole exchange, reported daily. This is the macro/regime signal.
- **Per-stock:** net foreign buy/sell and foreign ownership % on individual tickers.
- Because each broker code is itself tagged foreign or domestic, the per-stock broker summary already carries a foreign-vs-domestic split inside it.

### Slotting it back together
- **Market-wide foreign flow → top-down** ("what regime are we in").
- **Broker summary + per-stock foreign flow → bottom-up** ("is smart money behind this particular name").

### Caveat on bandarmology (it is over-trusted)
A broker on the buy side does **not** mean a single entity is accumulating:
- Brokers execute for many clients at once.
- Omnibus / nominee accounts hide the real beneficial owner.
- A "foreign" broker can trade for a domestic client, and vice versa.
- Crossings and internal transfers muddy the picture.

Treat it as a **noisy corroborating signal** to confirm or question a thesis built on fundamentals — not as proof of who is moving the stock, and not as the basis for a decision on its own.

---

## 3. Top-down — assessing market condition

IHSG is unusually macro- and flow-driven, so read the environment before any stock:

- **Macro:** IDR/USD and the BI (Bank Indonesia) rate. Rupiah weakness + foreign outflow is the classic risk-off combination.
- **Commodities:** the index leans heavily on coal, nickel, and CPO/palm oil — track these.
- **Foreign flow:** net foreign flow is a bigger swing factor on the IDX than in most markets.
- **Valuation:** index P/E and P/B as a **percentile vs. its own history**, not absolute levels.
- **Trend & breadth:** IHSG trend plus the share of LQ45 constituents above their 200-day moving average.

Output a regime read (risk-on / neutral / risk-off) that sets how aggressive to be.

---

## 4. Bottom-up — stock selection (value lens)

### Core screens (Graham-style)
- Margin of safety vs. Graham Number.
- NCAV (net current asset value) where it exists.
- P/B, earnings consistency over 5–10 years, balance-sheet strength.

### IDX-specific filters (these matter a lot)
- **Liquidity:** many small caps are too thin to exit cleanly — set a minimum daily value traded.
- **Governance / related-party risk:** emerging-market filings are prone to earnings management and related-party games. A statistically cheap stock can be a value trap. This is where forensic-accounting skill (and the broker-flow sanity check) earns its keep.

---

## 5. Paper trading with realistic IDX microstructure

This is where most paper trading lies to you. Model these honestly:

- **Lot size:** 100 shares = 1 lot.
- **Tick sizes:** tiered by price band.
- **ARA/ARB:** the daily auto-rejection price limits (Auto Rejection Atas/Bawah). You genuinely **cannot fill past them** — naïve backtests that assume otherwise are wrong.
- **Fees:** roughly 0.15–0.3% on buys, plus the ~0.1% sell tax (confirm your broker's exact schedule).
- **Fills:** assume the next available price, **never** the close.
- **Rules first:** entry, position size, stop, and exit are written *before* the trade.
- **Journal everything:** record the thesis with each trade so you can later separate good process from luck.

---

## 6. Measuring & iterating

- Benchmark total return against **IHSG total return** (not price-only).
- Track drawdown and hit rate.
- Review whether wins came from the **thesis** or from **beta/luck**.
- Iterate the **rules**, not the individual trades.

---

## Appendix A — Learning path (detail lives in the `investing-curriculum` skill)

Dependency-ordered phases, each with a paired practice task on a real company:

0. **Accounting literacy** — Graham & Meredith; Ittelson.
1. **Value philosophy & temperament** — Intelligent Investor (Zweig ed.); Cunningham/Buffett essays; Munger.
2. **Business & growth quality** — Fisher; Lynch.
3. **Valuation mechanics** — Damodaran.
4. **Forensic accounting (defense)** — Schilit et al.; O'Glove. *(Weighted for IDX.)*
5. **Judgment, risk & psychology** — Marks; Kahneman; Taleb; Bernstein.
6. **Macro & regime** — Marks on cycles; primary macro sources; the Zweig timing skill.

Counterpoint (parallel): Malkiel, *A Random Walk Down Wall Street*.
Free ongoing sources: Buffett's Berkshire letters; Marks's Oaktree memos; Damodaran Online.

*Titles verified from model knowledge without live web access — spot-check editions at purchase.*

---

## Appendix B — Credentials (detail in the per-credential skills)

Two distinct goals:

- **Analyst / portfolio path:** **CFA** (CFA Institute) — gold standard; overlaps with curriculum Phases 0–5. → `cfa-prep` skill.
- **Client-advising path:** **CFP** (FPSB / FPSB Indonesia) — holistic planning (investments, insurance, tax, retirement, estate). → `cfp-prep` skill.
- **Indonesia regulatory licenses (OJK; exams via TICMI):**
  - **WMI** (Wakil Manajer Investasi) — fund/portfolio management. → `wmi-prep` skill.
  - **WPPE** (Wakil Perantara Pedagang Efek) — securities brokerage. → `wppe-prep` skill.

Skill ≠ license: a capable analyst (CFA) is different from a regulated advisor (CFP) or a licensed Indonesian professional (WMI/WPPE).

*Exam structures, fees, the CFA's newer pieces (Practical Skills Modules, Level III pathways), and the WPPE tier names change — verify with the official bodies (CFA Institute, FPSB Indonesia, OJK/TICMI).*

---

## Be skeptical of "gurus"

Credibility tests, used to filter out most paid trading courses and influencer content (the bandarmology/day-trading course scene around the IDX is especially mixed): audited long-term track record, disclosed conflicts of interest, teaches **process not picks**, and makes **no return promises**.
