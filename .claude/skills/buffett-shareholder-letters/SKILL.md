---
name: buffett-shareholder-letters
description: >-
  Apply Warren Buffett's investing frameworks as laid out in his own words across the
  Berkshire Hathaway annual shareholder letters (1977–present): owner earnings,
  look-through earnings, intrinsic value, economic goodwill, economic franchises/moats,
  the institutional imperative, circle of competence, insurance float, and the
  one-dollar retained-earnings test. Use this skill whenever the user wants to analyze,
  value, or screen a company through a Buffett/Berkshire lens; asks about owner earnings,
  intrinsic value, moats, capital allocation, management quality, or "what would Buffett
  do"; references the Berkshire shareholder letters; or wants primary-source Buffett
  principles (as distinct from secondary syntheses such as Buffettology). Trigger even
  when the user just names a company and asks for a "Buffett-style," "quality business,"
  or "long-term owner" assessment.
---

# Buffett's Berkshire Shareholder Letters

This skill encodes the investing framework Buffett built and explained in the Berkshire
Hathaway annual letters. It is a *primary-source* lens: the goal is to think about a
business the way an owner-operator who plans to hold forever would, not to mechanically
score ratios. Where a secondary synthesis (e.g. Buffettology) hands you fixed numeric
thresholds, the letters hand you a way of reasoning. Use the numbers as evidence, not as
the verdict.

## The one-sentence summary

Buy a *wonderful business* — one with a durable economic franchise, run by honest and able
managers who allocate capital well — at a *price below its intrinsic value*, and hold it
while the franchise endures. ("It's far better to buy a wonderful company at a fair price
than a fair company at a wonderful price." — 1989 letter.)

Everything below is machinery in service of that sentence.

## Workflow

When asked to analyze or value a company through this lens, work through these stages in
order. Don't skip to valuation before establishing business quality — a precise value on a
deteriorating franchise is a precise wrong answer.

1. **Circle of competence check.** Can you actually understand how this business makes
   money and what it will look like in ten years? If not, say so and stop. Being honest
   about the boundary is the skill, not the size of the circle (1996 letter).
2. **Franchise vs. business.** Establish whether there is a real economic moat. See
   "Business-quality filters" below. No durable franchise → no long-term hold thesis.
3. **Owner earnings.** Translate reported GAAP earnings into the cash an owner can
   actually extract. See `references/calculations.md`.
4. **Returns on capital & the one-dollar test.** Does the business earn high returns on
   tangible capital, and has each retained dollar created at least a dollar of market
   value? See `references/calculations.md`.
5. **Management quality.** Are managers rational capital allocators who treat shareholders
   as partners? See "Management & capital allocation."
6. **Intrinsic value & margin of safety.** Discount owner earnings; compare to price;
   demand a margin of safety. See "Valuation."
7. **Risk.** Apply Buffett's definition of risk (permanent loss / inadequate return), not
   volatility. See "Risk."
8. **Verdict.** Synthesize into buy / hold-and-watch / pass, with the reasoning made
   explicit. Use the scorecard and decision tree in `references/checklist.md`.

For the full step-by-step checklist, scorecard, and decision tree, read
`references/checklist.md`. For every formula and worked example, read
`references/calculations.md`. For the complete glossary of concepts with letter
citations, read `references/concepts.md`.

## The core lens (philosophy in brief)

- **Be a business analyst, not a market analyst or a macro forecaster.** Value comes from
  the business's future cash, not from predicting where the stock or the economy goes.
- **Mr. Market is your servant, not your guide** (1987 letter, after Graham). The market
  quotes you a price every day; you are free to ignore it. Use his manic-depressive mood
  swings to buy, never let them tell you what your asset is worth.
- **Time is the friend of the wonderful business and the enemy of the mediocre one**
  (1989). A great franchise compounds; a poor business consumes capital while you wait.
- **Margin of safety** — Graham's three most important words. The gap between price and
  intrinsic value is what protects you from being wrong.
- **Volatility is not risk** (1993). Risk is the probability of permanent loss of capital
  or an inadequate return, not the wiggle of the share price.

## Business-quality filters

This is the heart of the letters. Decide whether you are looking at a *franchise* or a
*business* (1991 letter, "Economic Franchises").

An **economic franchise** arises from a product or service that:
1. is needed or desired by customers;
2. is thought by its customers to have **no close substitute**; and
3. is **not subject to price regulation.**

A franchise earns high returns on capital, can raise prices, and can survive mediocre
management. A plain **business** earns exceptional returns only if it is the low-cost
operator or while supply of its product is tight; it is unforgiving of weak management.

Probe the moat by asking what would happen if a well-funded, talented competitor tried to
take share. Sources of durable moats Buffett returns to: low-cost production scale, brand
and "share of mind" (See's Candies, Coca-Cola), switching costs, and regulatory or network
positioning. The **"Inevitables"** (1996) are the rare businesses — Coke, Gillette in his
telling — whose dominance over an investing lifetime is close to certain. Most companies
are not Inevitables; be skeptical of the label.

Test the moat with **economic goodwill** (1983 appendix, See's): a franchise earns far
above-market returns on *modest tangible assets*. That excess earning power, especially one
that grows with little incremental capital and holds up in inflation, is the moat made
quantitative. See `references/calculations.md`.

## Valuation

**Intrinsic value** = the discounted value of the cash that can be taken out of a business
over its remaining life (1994 owner's manual). Book value is what was *put in*; intrinsic
value is what will *come out*. They can differ enormously (the college-education analogy:
tuition is book value, the discounted lifetime earnings premium is intrinsic value).

The valuation engine is a discounted stream of **owner earnings**, not reported earnings.
The discount rate Buffett anchors to is the long-term risk-free (government bond) rate; he
demands extra margin rather than inflating the discount rate with a fudge factor.

The **Aesop framework** (2000 letter): valuing any financial asset is just "a bird in the
hand is worth two in the bush." To act you must answer three questions: (1) how *certain*
are you the birds are in the bush; (2) *when* will they emerge and *how many*; (3) what is
the risk-free rate? Answer those and you can compare any opportunity against any other on
one yardstick.

Then apply a **margin of safety**: only act when price sits meaningfully below your
intrinsic-value estimate, sized to your *uncertainty* about the business. A wider moat and
clearer economics justify a thinner margin; murkier futures demand a wider one.

## Management & capital allocation

Capital allocation is the single most important job of a CEO and the thing most CEOs are
worst at (1987). Judge management on:

- **Rationality with retained earnings** — reinvest only when each retained dollar will
  create at least a dollar of value; otherwise pay it out or buy back stock when it trades
  below intrinsic value (the dividend logic of the 2012 letter).
- **Candor** — do they report to owners the way they'd want to be reported to, owning up
  to mistakes? (Buffett's own letters are the model.)
- **Resisting the institutional imperative** — see Behavioral guardrails.
- **Treating shareholders as partners**, not as a funding source for empire-building.

## Risk

Reject beta and volatility as risk measures (1993). Assess risk by judging:
1. the certainty with which the long-term economics of the business can be evaluated;
2. the certainty with which management can be evaluated, both as to ability and to whether
   it will channel rewards to shareholders rather than itself;
3. the purchase price; and
4. levels of taxation and inflation that will determine real returns.

"Risk comes from not knowing what you're doing." The defense is the circle of competence
plus the margin of safety.

## Behavioral guardrails

- **The institutional imperative** (1989, "Mistakes of the First Twenty-Five Years"):
  organizations resist change; projects and acquisitions appear to soak up available funds;
  any business craving of the leader gets quickly supported by staff studies; and the
  behavior of peer companies is mindlessly imitated. Watch for all four in management — and
  in your own analysis.
- **Mr. Market** — don't let daily quotes become your scorecard for business value.
- **Stay inside the circle.** A clear "I don't understand this well enough" is a correct
  answer, not a failure.

## How this layers with other investing skills

This skill is the **long-term quality and capital-allocation lens**. It composes with the
others rather than replacing them:

- **Fisher (Super Stocks) PSR / scuttlebutt** → use for surfacing candidates and gauging
  growth quality before applying the franchise test here.
- **Lynch (One Up on Wall Street) categories & PEG** → use to classify the growth story
  and sanity-check the price paid for growth; this skill then asks whether the moat makes
  that growth *durable*.
- **Graham (Intelligent Investor) margin of safety & quality filters** → the philosophical
  parent of this skill; use Graham's quantitative quality/solvency screens as a floor, then
  use Buffett's franchise reasoning to decide what is worth holding for decades.
- **Zweig (Winning on Wall Street) monetary/momentum model** → orthogonal; use for *market
  timing* of entries, not for the business-quality judgment this skill governs.

Suggested ordering for a full workup: Fisher/Lynch to find and characterize → this skill +
Graham for the quality and value verdict → Zweig for timing the entry.

## Output expectations

When delivering an analysis, make the reasoning explicit and structured:
- State the circle-of-competence judgment first.
- Show owner-earnings and returns-on-capital math (with the assumptions, especially the
  maintenance-capex estimate, called out as estimates).
- Give a clear franchise / not-a-franchise verdict with the *reason*.
- Provide an intrinsic-value range (not a false-precision point estimate) and the implied
  margin of safety at the current price.
- Flag the two or three things that would most change the thesis.
Never present an estimate of maintenance capex, growth, or intrinsic value as a precise
fact — these are judgments, and the letters are emphatic that an approximately right answer
beats a precisely wrong one.

## Reference files

- `references/calculations.md` — formulas and worked examples: owner earnings,
  look-through earnings, the one-dollar retained-earnings test, economic goodwill, float
  and the cost of float, and the intrinsic-value (discounted owner-earnings) method.
- `references/concepts.md` — full glossary of the letters' concepts with the year each was
  most clearly articulated, for deeper context on any single idea.
- `references/checklist.md` — the analysis checklist, a weighted scorecard, and a
  buy/hold/pass decision tree.
