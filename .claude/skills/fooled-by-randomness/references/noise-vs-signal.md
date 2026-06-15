# Noise vs. Signal

A real edge is small relative to the random fluctuation around it. So the more frequently you observe a process, the more of what you see is **noise** and the less is **signal** — and the more emotional damage you take for no informational gain. This file gives the math and the practical rules.

## Contents
1. Why frequent observation drowns the signal
2. The frequency-of-up-moves calculation
3. The emotional asymmetry of checking
4. Practical rules
5. Diagnostic questions

---

## 1. Why frequent observation drowns the signal

Over a time interval Δt, the *expected* return scales with Δt, but the *fluctuation* (standard deviation) scales with √Δt. So as Δt shrinks toward an instant:

```
signal ∝ Δt        (mean drift)
noise  ∝ √Δt        (standard deviation)
signal-to-noise ∝ Δt / √Δt = √Δt  → 0 as Δt → 0
```

At short horizons the ratio collapses: you are looking almost entirely at noise. Stretch the horizon and signal grows faster than noise, and the edge becomes visible. **The information is in the long horizon; the short horizon is mostly randomness wearing the costume of news.**

## 2. The frequency-of-up-moves calculation

Take Taleb's dentist-investor with a genuinely good edge: expected return μ = 15% per year, volatility σ = 10% per year, so a strong Sharpe of 1.5. The probability of observing a *gain* when you check over a window that is a fraction Δt of a year:

```
P(up over Δt) = Φ( (μ/σ) · √Δt )
  Φ = standard normal CDF;  μ/σ = annual Sharpe = 1.5
```

| Checking interval | Δt (years) | P(see a gain) |
|---|---|---|
| 1 year | 1 | 93% |
| 1 quarter | 0.25 | 77% |
| 1 month | 1/12 | 67% |
| 1 day | 1/252 | ~54% |
| 1 hour (8h day) | 1/2016 | ~51% |
| 1 second | tiny | ~50.02% |

Same skilled investor, same edge. Checked yearly, he is delighted 93% of the time. Checked second-by-second, he sees a coin flip — and a brutal one (next section). **The edge didn't change; the observation frequency changed what's visible.**

## 3. The emotional asymmetry of checking

Two compounding problems with frequent observation:

1. **You mostly see noise**, so frequent checking provides almost no information to act on — but invites you to act anyway, churning a good strategy into a worse one.
2. **Losses hurt more than equivalent gains please** (loss aversion). At second-by-second checking, our skilled investor experiences roughly half losses and half gains, but the pain of the losing half outweighs the pleasure of the winning half. Over a year of constant monitoring he endures a torrent of small emotional negatives to reach an outcome that, checked once, would have felt purely good. He pays a large psychological tax for negative information.

The prescription: **match observation frequency to the horizon at which signal actually exists.** For a long-horizon strategy, checking daily is self-harm with no upside.

## 4. Practical rules

- Set the review cadence to the strategy's signal horizon, not to how often a screen *can* be refreshed. A multi-year thesis reviewed daily is almost all noise.
- Distinguish "the price moved" from "the thesis changed." Most intraday and daily moves are the former.
- Be especially wary of reacting to a single short-window observation; one data point at high frequency is essentially pure noise.
- When tempted to act on recent performance, ask whether the sample is long enough (see the (2σ/μ)² rule in `luck-vs-skill.md`) to mean anything.

## 5. Diagnostic questions

- Over what horizon is the conclusion being drawn, and is that long enough for signal to exceed noise?
- Is someone reacting to a price move or to genuine new information about the underlying thesis?
- How often is the observer checking, and is that cadence matched to the signal horizon or just to availability?
- Is recent short-window performance being mistaken for evidence about the strategy's quality?
