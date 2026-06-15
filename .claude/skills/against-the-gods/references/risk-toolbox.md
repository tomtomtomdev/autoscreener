# Risk Toolbox — Formulas and Worked Examples

The quantitative instruments from *Against the Gods*. Each entry: the idea, the formula, a worked
example, and the trap to avoid. Use these for steps 3–5 and 7 of the response framework.

## Table of Contents
1. Expected Value (Pascal & Fermat)
2. Utility & Diminishing Marginal Value (Daniel Bernoulli) + St. Petersburg Paradox
3. Pascal's Wager (asymmetric consequences)
4. The Law of Large Numbers (Jacob Bernoulli)
5. The Normal Distribution and Its Fat-Tailed Limits (de Moivre, Gauss)
6. Regression to the Mean (Galton)
7. Bayes' Theorem (Bayes)
8. Diversification & Portfolio Risk (Markowitz)

---

## 1. Expected Value (Pascal & Fermat)

The founding tool of probability, born from the 1654 Pascal–Fermat correspondence over how to split the
stakes of an interrupted game of chance.

**Formula:**
```
EV = Σ (probabilityᵢ × payoffᵢ)
```

**Worked example.** A bet costs $10. It pays $100 with probability 0.08, otherwise $0.
EV = (0.08 × $100) + (0.92 × $0) = $8. You pay $10 for $8 of expected value → **negative-EV bet,
decline.** Flip it: if the same payoff cost $5, EV $8 > $5 → positive edge.

**The trap.** EV treats $1 and the millionth dollar as equal, and treats a repeatable bet the same as a
one-shot bet you can't survive losing. For large or irreversible stakes, EV is the wrong yardstick — go
to utility (§2) and Pascal's Wager (§3).

---

## 2. Utility & Diminishing Marginal Value (Daniel Bernoulli, 1738)

Bernoulli's breakthrough: people value money by its **utility to them**, not its face amount. The
hundredth thousand dollars matters far less to a rich person than the first thousand does to a poor one.
This *diminishing marginal utility* is why rational people are risk-averse and buy insurance.

**Logarithmic utility (Bernoulli's proposed form):**
```
U(wealth) = ln(wealth)      → decide by maximizing EXPECTED UTILITY, not expected wealth
```

**St. Petersburg Paradox (the case that forced the idea).** A coin is flipped until it lands heads. If
heads comes on flip n, you win 2ⁿ ducats. The expected *money* is:
```
EV = Σ (½ⁿ × 2ⁿ) = ½ + ½ + ½ + ... = ∞
```
Infinite expected value — yet no sane person pays more than a few coins to play. Expected *money* fails;
expected *utility* (with diminishing marginal value) gives a small, sensible price. **Lesson: when the
payoff distribution is skewed or the stakes are large, maximize utility, not dollars.**

**Practical use.** Ask: "What does this outcome mean to *this* decision-maker, given their total
resources?" A $50k loss is a rounding error to one person and ruin to another. Size the bet to the
*utility* consequence, never the headline EV. (Modern bet-sizing tools like the Kelly criterion descend
directly from this log-utility idea — flag that as a modern extension, not from the book, if it helps.)

---

## 3. Pascal's Wager (Asymmetric Consequences)

Pascal's argument about belief in God is, stripped of theology, a **decision rule for asymmetric
payoffs**: when the consequence of being wrong is enormous and the cost of insuring against it is small,
the *magnitude* of the consequence dominates the *probability*.

**Use it when:** one branch is catastrophic or irreversible (ruin, death, default), even if unlikely.

**Worked reasoning.** Suppose an investment has a 95% chance of a 10% gain and a 5% chance of total
ruin. EV may look positive, but the 5% ruin branch ends the game — you never get to play the favorable
odds again. Pascal's logic says: pay to avoid the catastrophic branch (hedge, insure, size down, keep
reserves) even though it's "probably" fine. **"Probably fine" is not good enough when "not fine" is
permanent.** This is the deep structure of margin of safety and insurance.

---

## 4. The Law of Large Numbers (Jacob Bernoulli, 1713)

Over many **independent** trials of a stable process, the observed frequency converges to the true
probability. This is what makes insurance and casinos work: the house edge is unreliable on one spin
but iron-clad over a million.

**Two traps Bernstein stresses:**
- **"Large" can be very large.** Convergence is slow; small samples are noisy. A fund's three good years
  prove almost nothing.
- **It requires stable, independent trials.** If the underlying probability shifts (a regime change) or
  trials are linked (correlated defaults), the law gives false comfort. Applying it to *single,
  one-shot, or non-stationary* events is the **gambler's fallacy's respectable cousin**.

---

## 5. The Normal Distribution and Its Fat-Tailed Limits (de Moivre 1730, Gauss)

The bell curve: many measurements cluster symmetrically around a mean, with ~68% within one standard
deviation (σ), ~95% within 2σ, ~99.7% within 3σ.

**Why it matters and why it's dangerous in finance.** The normal distribution is the backbone of most
risk models — and Bernstein's repeated warning is that **markets are not normal**. Real returns have
*fat tails*: extreme moves (crashes, manias) happen far more often and far larger than the bell curve
predicts. A "25-standard-deviation event" should be impossible in millennia under normality, yet such
days recur every decade or two.

**Practical use.** Use the bell curve for rough variation, but never trust it in the tails. When someone
quotes a Value-at-Risk or a "3-sigma" comfort, ask what the model assumes and what happens beyond it.
The map is not the territory; the tail is where you die.

---

## 6. Regression to the Mean (Francis Galton, 1880s)

Galton found that tall parents have children shorter than themselves (closer to average), and short
parents have taller ones. Extreme outcomes are **partly luck**, and luck doesn't repeat — so extremes
tend to be followed by more ordinary ones.

**Precise statement (standardized units):**
```
predicted z-score of outcome = r × observed z-score of predictor
```
where `r` is the correlation. The lower the correlation (the more luck involved), the harder the pull
back toward the mean.

**Worked example.** A fund beats the market by a huge margin this year. If skill explains only part of
the result (r is moderate), the best forecast for next year is **much closer to average**, not a repeat.
Same for a star salesperson's record month, a student's outlier test, a stock's blowout quarter.

**Two traps:**
- **Don't extrapolate extremes.** Projecting a peak (or a trough) forward is the core error behind buying
  hot performers and bubbles.
- **Regression is not a force.** It does not *guarantee* reversal, it does not "remember" what's owed,
  and the mean itself can drift. It's a statistical tendency, not a law of physics.

---

## 7. Bayes' Theorem (Thomas Bayes, published 1763)

How to revise a probability as new evidence arrives — start with a **prior** (often the base rate),
update to a **posterior**.

**Formula:**
```
P(A | B) = [ P(B | A) × P(A) ] / P(B)
```

**Worked example (the base-rate lesson).** A test for a disease is 99% accurate. The disease afflicts
1 in 10,000 people. You test positive. What's the chance you're actually sick?
- Prior P(sick) = 0.0001
- Out of 10,000 people: ~1 true case (likely caught) + ~100 false positives (1% of 9,999).
- P(sick | positive) ≈ 1 / (1 + 100) ≈ **under 1%.**

Despite a "99% accurate" test, you're probably fine — because the base rate is tiny. **Ignoring the base
rate in favor of the vivid new signal is one of the most expensive errors humans make.** Always anchor on
the prior, then update.

---

## 8. Diversification & Portfolio Risk (Harry Markowitz, 1952)

Markowitz showed you cannot judge an asset's risk in isolation — only by how it **combines** with the
rest of the portfolio. Often called "the only free lunch in finance."

**Two-asset portfolio variance:**
```
σ²_portfolio = w₁²σ₁² + w₂²σ₂² + 2·w₁·w₂·ρ·σ₁·σ₂
```
where w = weights, σ = each asset's volatility, ρ = correlation between them.

**The key insight is ρ.** When correlation is low or negative, the cross term shrinks (or subtracts) and
portfolio risk falls **below** the weighted average of the parts — risk reduction for free. When ρ = 1
(assets move together), there's no benefit at all.

**Worked intuition.** Ten stocks that all rise and fall together are barely safer than one. Ten stocks
that move independently are dramatically safer than any one. **Diversification works only to the extent
holdings are uncorrelated.**

**The crisis trap (Bernstein's warning).** Correlations are not stable. In a panic, things that normally
move independently all crash together — ρ jumps toward 1 exactly when you need diversification most. The
free lunch is smallest in the storm. Plan for it.
