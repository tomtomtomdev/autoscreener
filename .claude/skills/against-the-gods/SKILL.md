---
name: against-the-gods
description: >
  Apply the risk and probability frameworks from Peter L. Bernstein's *Against the Gods: The Remarkable
  Story of Risk* to reason about decisions under uncertainty. Use whenever the user weighs a risky
  decision, estimates odds, sizes a bet or position, evaluates a forecast, or wants to think clearly
  about an uncertain future — in investing, business, gambling, insurance, or everyday choices. Trigger
  on questions like "what are the odds?", "is this a good bet?", "how should I size this?", or any
  request involving probability, expected value, utility, regression to the mean, base rates, Bayesian
  updating, diversification, tail risk, loss aversion, or cognitive bias. Also trigger on mentions of
  Bernstein, Pascal, Bernoulli, Bayes, Galton, Markowitz, Kahneman, Knightian uncertainty, fat tails,
  or prospect theory. This is the risk-management lens complementing stock-picking skills (Graham,
  Fisher, Lynch, Buffett, Zweig): they pick and time investments; this governs probability, sizing, and
  the psychology of risk.
---

# Against the Gods Skill

This skill lets Claude reason about uncertain decisions using the intellectual toolkit assembled in
Peter L. Bernstein's *Against the Gods: The Remarkable Story of Risk* (1996). The book is a history of
how humanity learned to measure and manage risk — from Renaissance gamblers to modern portfolio theory
and behavioral economics. This skill turns that history into a practical lens for thinking.

It is NOT financial advice and NOT a forecasting oracle. It is a disciplined way to reason about
probability, consequence, and human fallibility. Remind the user of this when stakes are real, and
suggest a qualified professional for personal financial, legal, or medical decisions.

---

## The One Big Idea (Read First)

> *"The revolutionary idea that defines the boundary between modern times and the past is the mastery
> of risk: the notion that the future is more than a whim of the gods and that men and women are not
> passive before nature."* — Bernstein

Bernstein's grand theme is a **tension between two worlds**:

1. **The measurable world** — probability theory, expected value, the bell curve, diversification.
   Powerful tools that let us quantify risk and make rational choices.
2. **The human world** — emotion, bias, memory, fear, greed. People do not behave like the rational
   agents the models assume.

Good risk thinking lives in the gap between them. The recurring failure mode across the whole book is
**mistaking a model for reality** — trusting a clean equation built on assumptions (stable
probabilities, normal distributions, rational actors) that the messy future violates. So every analysis
should do two things at once: *use the math*, and *distrust the math's assumptions*.

Bernstein's definition of the discipline:

> *"The essence of risk management lies in maximizing the areas where we have some control over the
> outcome while minimizing the areas where we have no control over the outcome and the linkage between
> effect and cause is hidden from us."*

---

## The Core Distinction: Risk vs. Uncertainty

Before any analysis, classify what you are facing. This is the Knight/Keynes distinction Bernstein
emphasizes:

- **Risk** — outcomes are unknown but the *probabilities are knowable* (a fair die, a large insurance
  pool, a well-understood repeatable process). Here the probability tools work.
- **Uncertainty** — the probabilities themselves are unknown or unknowable (a novel geopolitical event,
  a once-in-a-century crisis, a brand-new technology). Here, assigning a precise number is **false
  precision**, and the right move is humility, robustness, and margin of safety — not a sharper point
  estimate.

**The cardinal sin** is dressing uncertainty up as risk: inventing a confident "23% probability" for
something genuinely unknowable, then acting as if that number were solid. When you catch yourself or
the user doing this, name it.

---

## How to Analyze Any Risky Decision (Response Framework)

When the user brings a decision, forecast, or bet, work through these steps. Skip ones that don't
apply, but always do step 1 and step 7.

1. **Classify: risk or uncertainty?** Are the probabilities knowable or are we guessing? Set the
   ambition of the analysis accordingly. (See "Core Distinction" above.)

2. **Separate probability from consequence.** A decision has two axes: *how likely* and *how much it
   matters*. People routinely collapse them. A 1% chance of ruin is not "basically zero" — the
   consequence is permanent. A 90% chance of a tiny gain may not be worth a 10% chance of catastrophe.

3. **Compute expected value — then check whether EV is even the right yardstick.** EV = Σ(probability ×
   payoff). But when outcomes are large relative to your total wealth, or losses are irreversible, switch
   to **utility/consequence thinking** (Daniel Bernoulli). See `references/risk-toolbox.md`.

4. **Find the base rate, then update (Bayes).** What normally happens in situations like this? Start
   there, then revise with the specific evidence. Ignoring the base rate in favor of a vivid story is
   one of the most common and costly errors. See `references/risk-toolbox.md`.

5. **Check for regression to the mean.** Is this estimate built on an extreme recent observation (a hot
   streak, a disastrous quarter, a star performer)? Extremes tend to be followed by less extreme
   outcomes. Don't extrapolate the peak or the trough. See `references/risk-toolbox.md`.

6. **Run the bias scan.** Is the reasoning — yours, the user's, or the market's — distorted by loss
   aversion, framing, anchoring, availability, overconfidence, or recency? See
   `references/behavioral-biases.md`.

7. **Stress the tails and the model.** What does the analysis assume? What happens if returns aren't
   normal (fat tails), if correlations spike to 1 in a crisis, if the probabilities aren't stable?
   What's the worst case, and can you survive it? Maximize control where you have it; build margin
   where you don't.

Then give the user a clear read: what the numbers say, what the numbers *assume*, and where the real
risk hides.

---

## The Toolkit at a Glance

Each tool below is detailed with formulas and worked examples in `references/risk-toolbox.md`. Read that
file whenever a decision turns on one of these. This table is the index.

| Tool | Origin (per Bernstein) | What it does | When to reach for it |
|---|---|---|---|
| **Expected value** | Pascal & Fermat | Weighs each outcome by its probability | Any repeatable bet with knowable odds |
| **Utility / diminishing marginal value** | Daniel Bernoulli | Values outcomes by what they mean *to you*, not face value | Large stakes relative to your wealth; risk of ruin |
| **Pascal's Wager logic** | Pascal | When consequences are wildly asymmetric, magnitude dominates probability | Tail risks, irreversible losses, insurance-type decisions |
| **Law of Large Numbers** | Jacob Bernoulli | Frequencies converge to true odds *over many independent trials* | Insurance pools, casinos, large samples — NOT single events |
| **The bell curve & its limits** | de Moivre, Gauss | Many outcomes cluster around a mean; but tails are fatter than normal in markets | Modeling variation — with explicit skepticism about extremes |
| **Regression to the mean** | Galton | Extreme observations tend to be followed by less extreme ones | Evaluating streaks, star/dud performance, "this time is different" |
| **Bayesian updating** | Bayes | Revise a prior probability as evidence arrives | Diagnosing, forecasting, any belief that should move with new data |
| **Diversification / portfolio risk** | Markowitz | Risk depends on how holdings *combine* (correlation), not each alone | Sizing a portfolio of bets; "the only free lunch" |
| **Game theory** | von Neumann & Morgenstern | Outcomes depend on other rational actors also strategizing | Negotiations, competitive markets, auctions |
| **Prospect theory & biases** | Kahneman & Tversky | Humans deviate from rationality in systematic, predictable ways | Always — to audit the reasoning itself |

---

## Quick Reference Card

- **Two axes, always:** probability AND consequence. Never one without the other.
- **EV for the repeatable, utility for the existential.** A positive-EV bet that can wipe you out is
  still a bad bet.
- **Survive first.** "In order to win, first you must not lose." Avoid irreversible ruin before chasing
  upside.
- **Base rate first, story second.** The vivid narrative is usually less informative than the boring
  base rate.
- **Extremes regress.** The best year and the worst year are both bad forecasts of next year.
- **Diversify what's uncorrelated.** Combining bets that don't move together lowers risk for free;
  combining bets that secretly move together does nothing — and correlations rise in crises.
- **The bell curve lies in the tails.** Real-world disasters are more frequent and more severe than a
  normal distribution predicts.
- **Distrust your model in proportion to your confidence in it.** Overconfidence in a clean model is the
  signature of the biggest blowups in the book.
- **"The information you have is not the information you want. The information you want is not the
  information you need. The information you need is not the information you can obtain."**

---

## Reference Files

- **`references/risk-toolbox.md`** — The quantitative tools with formulas and worked examples: expected
  value, utility & the St. Petersburg paradox, the Law of Large Numbers, the normal distribution and
  fat tails, regression to the mean, Bayes' theorem, and Markowitz diversification. Read this whenever a
  decision turns on a calculation.
- **`references/behavioral-biases.md`** — The Kahneman–Tversky catalog of biases (loss aversion,
  framing, anchoring, availability, overconfidence, representativeness/base-rate neglect, recency,
  hindsight, the gambler's fallacy). Each with a detection cue and a countermeasure. Read this for
  step 6 of the framework, or whenever the reasoning *feels* off.
- **`references/history-and-figures.md`** — The narrative arc and the cast of characters, for context,
  attribution, and accurate quoting. Read this when the user wants the story, the history, or to cite
  who originated an idea.

---

## How This Pairs With Other Skills

If the user also has the value/growth investing skills (Graham's *Intelligent Investor*, Fisher's *Super
Stocks*, Lynch's *One Up on Wall Street*, *Buffettology*, Zweig's *Winning on Wall Street*), this skill
is the **risk-management layer that sits above all of them**. Those skills answer *what to buy* and
*when*; this one answers *how much to risk, how to size it, how to weigh the odds, and which
psychological traps are distorting the decision*. Concretely:

- Graham's **margin of safety** is Pascal's Wager logic applied to price: protect against the downside
  you can't foresee.
- Lynch's warning against chasing hot stocks is **regression to the mean**.
- Diversification questions ("how many stocks? how correlated?") are **Markowitz**.
- "This time is different" and panic selling are **availability, recency, and loss aversion**.
- Position sizing under genuine unknowns is **risk vs. uncertainty** plus **utility thinking**.

When a question blends stock selection with risk, use both lenses and say which is which.

---

## Caveats (State These When Stakes Are Real)

- This is a thinking framework, not financial, legal, or medical advice.
- Bernstein's deepest lesson is humility: the tools quantify risk but cannot tame genuine uncertainty.
  Treat every probability estimate as provisional.
- The biggest disasters in the book came from *over-trusting* the math (assuming normality, stable
  correlations, rational actors). Match the precision of your conclusion to the quality of your inputs.
- Past data describes the past. The future is under no obligation to resemble it.
