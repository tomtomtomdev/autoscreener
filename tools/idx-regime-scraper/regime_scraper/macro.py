"""Pure parsing for the global macro series that anchor the left end of the
intermarket chain — US fed funds (``DFF``), the US 10y Treasury yield (``DGS10``)
and the broad trade-weighted dollar (``DTWEXBGS``), all from FRED CSV.

Kept separate from ``bi_rate`` because the value semantics differ: a policy rate is a
small, bounded percentage (``parse_rate`` enforces ``0 < x < 50``), but the dollar
index trades around 120 — so these need a magnitude-agnostic value parser. The date
parsing and chronological sort are shared from ``bi_rate``.
"""

from __future__ import annotations

import csv
import io
from typing import List, Optional

from .bi_rate import Observation, parse_date, sort_observations
from .models import MacroSeries


def parse_fred_value(text: str) -> Optional[float]:
    """A FRED numeric cell, magnitude-agnostic. ``"."`` (FRED's missing marker),
    blanks and ``"-"`` → ``None``. Unlike ``parse_rate`` it applies no plausibility
    bound, so a 10y yield of ``4.30`` and a dollar index of ``121.5`` both parse."""
    s = text.strip()
    if s in ("", ".", "-", "N/A", "n/a"):
        return None
    s = s.replace(",", "")
    try:
        return float(s)
    except ValueError:
        return None


def parse_fred_series(text: str) -> List[Observation]:
    """FRED ``fredgraph.csv?id=<SERIES>`` — ``observation_date,value`` rows, ``"."``
    marks a missing value. Same envelope as the BI-rate CSV path but value-permissive."""
    out: List[Observation] = []
    rows = list(csv.reader(io.StringIO(text)))
    for row in rows[1:]:  # skip header
        if len(row) < 2:
            continue
        value = parse_fred_value(row[1])
        if value is None:
            continue
        out.append((row[0].strip(), value))
    return out


def trend(observations: List[Observation], lookback: int = 20) -> str:
    """Direction of a chronological series over a ``lookback`` window: ``up`` / ``down``
    / ``flat``. Compares the latest observation to the one ``lookback`` steps back
    (clamped to the oldest available), so daily series read as a ~1-trading-month trend
    rather than flapping on single-day noise. ``flat`` when too short or unchanged."""
    if len(observations) < 2:
        return "flat"
    steps = min(lookback, len(observations) - 1)
    last = observations[-1][1]
    ref = observations[-1 - steps][1]
    if last > ref:
        return "up"
    if last < ref:
        return "down"
    return "flat"


def to_macro_series(observations: List[Observation]) -> Optional[MacroSeries]:
    """Build the ``MacroSeries`` from a (possibly unsorted) observation list: sort
    chronologically, take the latest as the level, derive the trend. ``as_of`` is
    normalised to ISO so it agrees with the rest of the contract."""
    series = sort_observations(observations)
    if not series:
        return None
    as_of_raw, value = series[-1]
    parsed = parse_date(as_of_raw)
    as_of = parsed.isoformat() if parsed else as_of_raw
    return MacroSeries(value=value, trend=trend(series), as_of=as_of)
