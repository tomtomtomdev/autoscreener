# Luck vs. Skill

The central forensic question of *Fooled by Randomness*: when someone has a winning record, is it skill, or are we looking at a survivor of a large random process — a "lucky fool"? This file gives the reasoning tools and the math to tell them apart, or to admit honestly when you can't.

## Contents
1. The lucky-fool engine (survivorship bias)
2. The by-chance baseline (how many winners luck alone produces)
3. Ergodicity and the dentist (cross-sectional vs. time-series probability)
4. Track-record forensics: how long a record do you need?
5. The t-statistic test for an edge
6. Practical diagnostic questions

---

## 1. The lucky-fool engine (survivorship bias)

We observe records *conditional on survival*. The thousands who played the same game and lost are gone — they don't write books, run funds, or give interviews. So the surviving record systematically overstates skill, because the selection itself manufactures impressive-looking sequences from pure noise.

Taleb's thought experiment: start 10,000 managers, each with a coin-flip (50%) chance of beating the market in a given year purely by luck, no skill at all.

| Year | Expected managers still "perfect" |
|---|---|
| 0 | 10,000 |
| 1 | 5,000 |
| 2 | 2,500 |
| 3 | 1,250 |
| 4 | 625 |
| 5 | ~313 |

After five years, roughly **313 managers have beaten the market five years running by luck alone.** Each looks like a genius. Each can tell a compelling story. None has any skill. The graveyard of 9,687 is invisible.

**Implication:** "Beat the market N years in a row" is almost meaningless without knowing the size of the starting population. The bigger the population, the more spectacular the luck-driven survivors.

## 2. The by-chance baseline

Before crediting skill, compute what luck alone would produce. Two quick tools:

**Expected lucky survivors:**
```
E[survivors] = N · p^k
  N = number who started
  p = per-period probability of "winning" by luck (≈ 0.5 for beat/miss a benchmark)
  k = number of consecutive winning periods
```
Example: N = 10,000, p = 0.5, k = 5 → 10,000 · 0.5^5 = 312.5 lucky survivors.

**Probability a *given* person gets a perfect streak by luck:**
```
P(streak) = p^k
```
0.5^5 = 3.1%. Rare for one named person picked in advance — but near-certain that *someone* in a large field will do it. This is the core confusion: a low individual probability becomes a high population probability. Be impressed only if the winner was named *before* the run, not selected *after*.

## 3. Ergodicity and the dentist

Taleb contrasts a successful **dentist** with a successful **speculator**. The dentist earns a steady, skill-based income; replay her life a thousand times and she does well in nearly all of them. The lucky speculator did well in *this* history but would blow up in most alternative ones.

- **Cross-sectional probability** (ensemble): pick one moment, look across many people. At any instant, some speculators are rich.
- **Time-series probability** (per person, over time): follow one person across many periods.

A process is **ergodic** when the time average equals the ensemble average — when "what happens to one person over a long time" matches "what happens to many people at one time." Wealth built through fragile, leveraged bets is *non-ergodic*: the ensemble may show winners, but any single path eventually hits the absorbing barrier (ruin). Mistaking cross-sectional success for time-series robustness is a classic error. **Ask: would this record survive being lived a thousand times, or only in the lucky branch we happen to be standing in?**

## 4. Track-record forensics: how long a record do you need?

A real edge is buried in volatility, so short records can't reveal it. The number of years needed to distinguish a true excess return (alpha) μ from zero, at volatility σ, for rough statistical significance (t ≈ 2):

```
T ≈ (2σ / μ)²    years
```

| True alpha μ | Volatility σ | Years to detect (t≈2) |
|---|---|---|
| 10% | 10% | 4 |
| 5% | 15% | 36 |
| 3% | 20% | ~178 |
| 1% | 15% | 900 |

The lesson is sobering: a manager with a genuine but modest 3% edge and ordinary volatility needs **a lifetime or more** of data before the skill is statistically visible. So a 3-, 5-, or even 10-year record usually *cannot* separate skill from luck for typical edges. The honest verdict for most track records is "the sample is too short to tell" — and that is a legitimate, Taleb-approved answer.

## 5. The t-statistic test for an edge

To assess an existing record rather than plan one:

```
t = (mean periodic excess return / std dev of excess return) · √(number of periods)
  = (annual Sharpe ratio) · √(years)
```

Interpretation (rough): |t| < 2 → cannot reject "pure luck"; |t| ≈ 2 → marginal; |t| > 3 → stronger evidence of a real edge. A glorious 5-year run with a Sharpe of 0.7 gives t ≈ 0.7·√5 ≈ 1.6 — **not significant.** Caveats that make even a high t suspect: returns are fat-tailed (so the t-test understates tail risk), the record may be cherry-picked or back-filled, and a negative-skew strategy can post a high Sharpe right up until the blow-up (see `asymmetry-and-tails.md`).

## 6. Practical diagnostic questions

- How many people / funds / strategies started the same game? (Estimate the population, then the by-chance survivors.)
- Was this winner named *before* or *after* the run?
- What is the volatility, and is the record long enough — by the (2σ/μ)² rule — to carry any signal at all?
- Where are the losers? What happened to those who used a similar approach and didn't survive?
- Has the record been earned across different regimes, or only in the conditions that favor it?
- Is the strategy implicitly short a rare event that simply hasn't occurred yet? (If so, the smoothness is the warning, not the reassurance — go to `asymmetry-and-tails.md`.)
