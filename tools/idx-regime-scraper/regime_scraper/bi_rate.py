from __future__ import annotations

import csv
import io
import re
from datetime import date
from typing import List, Optional, Tuple

from .models import BIRate

# A parsed observation: (original date string, rate). The original string is carried
# through sorting (which parses it for ordering); `to_bi_rate` normalises it to ISO.
Observation = Tuple[str, float]

_MONTHS = {
    # English
    "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6,
    "july": 7, "august": 8, "september": 9, "october": 10, "november": 11, "december": 12,
    # Indonesian (bi.go.id renders dates in Bahasa)
    "januari": 1, "februari": 2, "maret": 3, "mei": 5, "juni": 6, "juli": 7,
    "agustus": 8, "oktober": 10, "desember": 12,
    # short forms
    "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7, "aug": 8, "agu": 8,
    "sep": 9, "oct": 10, "okt": 10, "nov": 11, "dec": 12, "des": 12,
}


def parse_date(text: str) -> Optional[date]:
    """Parse the handful of date shapes BI / FRED emit: ISO ``2026-01-15``,
    ``DD Month YYYY`` (English or Bahasa), and ``DD/MM/YYYY``. ``None`` if no match."""
    s = text.strip()
    m = re.search(r"(\d{4})-(\d{1,2})-(\d{1,2})", s)
    if m:
        return _safe_date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    m = re.search(r"(\d{1,2})\s+([A-Za-z]+)\.?\s+(\d{4})", s)
    if m:
        month = _MONTHS.get(m.group(2).lower())
        if month:
            return _safe_date(int(m.group(3)), month, int(m.group(1)))
    m = re.search(r"(\d{1,2})[/-](\d{1,2})[/-](\d{4})", s)
    if m:
        return _safe_date(int(m.group(3)), int(m.group(2)), int(m.group(1)))
    return None


def _safe_date(year: int, month: int, day: int) -> Optional[date]:
    try:
        return date(year, month, day)
    except ValueError:
        return None


def parse_rate(text: str) -> Optional[float]:
    """Parse a percentage cell: ``4.75``, ``4,75``, ``4.75%``, ``5,75 %``. Handles
    the Bahasa decimal comma. ``None`` if it doesn't look like a rate."""
    s = text.strip().replace("%", "").strip()
    if not s:
        return None
    # Decimal comma (no dot present) → dot; otherwise commas are thousands separators.
    if "," in s and "." not in s:
        s = s.replace(",", ".")
    else:
        s = s.replace(",", "")
    if not re.fullmatch(r"-?\d+(\.\d+)?", s):
        return None
    try:
        value = float(s)
    except ValueError:
        return None
    # A policy rate is a small positive percentage; reject anything implausible so a
    # stray numeric cell can't be mistaken for the rate.
    return value if 0.0 < value < 50.0 else None


def sort_observations(observations: List[Observation]) -> List[Observation]:
    """Chronological ascending, dropping rows whose date can't be parsed — so the
    result is correct whether the source table was oldest- or newest-first."""
    dated = [(parse_date(d), (d, r)) for d, r in observations]
    dated = [(pd, obs) for pd, obs in dated if pd is not None]
    dated.sort(key=lambda t: t[0])
    return [obs for _, obs in dated]


def parse_fred_csv(text: str) -> List[Observation]:
    """FRED ``fredgraph.csv?id=IRSTCB01IDM156N`` — ``date,value`` rows, ``.`` = missing."""
    out: List[Observation] = []
    rows = list(csv.reader(io.StringIO(text)))
    for row in rows[1:]:  # skip header
        if len(row) < 2:
            continue
        rate = parse_rate(row[1])
        if rate is None:
            continue
        out.append((row[0].strip(), rate))
    return out


def parse_bi_rate_html(html: str) -> List[Observation]:
    """Scrape the BI-Rate history table (``bi.go.id/.../BI-Rate.aspx`` — server-rendered
    HTML, no Cloudflare). Heuristic and resilient to the exact markup: scan every table
    row and keep the (date, rate) pair when one cell parses as a date and another as a
    rate. The CSS structure of the live page may shift; this avoids brittle selectors."""
    from bs4 import BeautifulSoup  # local import: only the live path needs bs4

    soup = BeautifulSoup(html, "html.parser")
    out: List[Observation] = []
    for tr in soup.find_all("tr"):
        cells = [c.get_text(" ", strip=True) for c in tr.find_all(["td", "th"])]
        date_cell = next((c for c in cells if parse_date(c) is not None), None)
        # The BI-Rate column is rendered with a percent sign; prefer it so the leading
        # "No" index column — a bare integer that also parses as a plausible rate — can't
        # be read as the rate. Fall back to any rate-like cell if the page drops '%'.
        rate_cell = next((parse_rate(c) for c in cells if "%" in c and parse_rate(c) is not None), None)
        if rate_cell is None:
            rate_cell = next((parse_rate(c) for c in cells if parse_rate(c) is not None), None)
        if date_cell and rate_cell is not None:
            out.append((date_cell, rate_cell))
    return out


def direction(observations: List[Observation]) -> str:
    """Last policy move from a chronological series: ``hike`` / ``cut`` / ``hold``
    (equal latest two = held)."""
    if len(observations) < 2:
        return "hold"
    prev, last = observations[-2][1], observations[-1][1]
    if last > prev:
        return "hike"
    if last < prev:
        return "cut"
    return "hold"


def to_bi_rate(observations: List[Observation]) -> Optional[BIRate]:
    """Build the ``BIRate`` from a (possibly unsorted) observation list: sort
    chronologically, take the latest as the level, derive the direction. ``as_of`` is
    normalised to ISO (``2026-05-20``) so both the BI-HTML and FRED paths — and the
    published ``regime.json`` contract — agree on date shape."""
    series = sort_observations(observations)
    if not series:
        return None
    as_of_raw, value = series[-1]
    parsed = parse_date(as_of_raw)  # sort_observations dropped unparseable rows, so this holds
    as_of = parsed.isoformat() if parsed else as_of_raw
    return BIRate(value=value, direction=direction(series), as_of=as_of)
