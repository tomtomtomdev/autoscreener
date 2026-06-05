from __future__ import annotations

from typing import Iterable, Optional


def percentile_rank(value: Optional[float], history: Iterable[Optional[float]]) -> Optional[float]:
    """Fraction of historical observations ≤ ``value`` → the index's valuation
    percentile vs. its own history (``idx-regime-data-research.md`` §3, §5).

    Returns a value in ``[0, 1]`` (0 = cheapest in the series, 1 = most expensive),
    or ``None`` when ``value`` or the history is empty. The current observation is
    expected to be included in ``history`` so the newest point ranks against itself;
    over a 5–10y monthly series the self-count is negligible.
    """
    if value is None:
        return None
    values = [h for h in history if h is not None]
    if not values:
        return None
    at_or_below = sum(1 for h in values if h <= value)
    return at_or_below / len(values)
