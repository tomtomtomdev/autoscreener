"""Live HTTP — the only impure part of the scraper. Kept thin and separate so the
pure logic (``aggregate``/``percentile``/``bi_rate``/``build``) is fully unit-tested
without a network. ``curl_cffi`` is imported lazily because (a) it's only needed for
the Cloudflare-gated IDX endpoint and (b) the test suite must import the package
without it installed.

Sources (``idx-regime-data-research.md`` §3–§4):
  • IDX  LINK_FINANCIAL_DATA_RATIO  — Cloudflare-gated JSON → curl_cffi TLS impersonation
  • bi.go.id BI-Rate.aspx            — plain server-rendered HTML
  • FRED IRSTCB01IDM156N             — CSV fallback / cross-check
"""

from __future__ import annotations

from typing import List, Optional
from urllib.request import Request, urlopen

from .bi_rate import parse_bi_rate_html, parse_fred_csv, to_bi_rate
from .models import BIRate, StockRatio

IDX_RATIO_URL = "https://www.idx.co.id/primary/DigitalStatistic/GetApiDataPaginated"
BI_RATE_URL = "https://www.bi.go.id/id/statistik/indikator/BI-Rate.aspx"
FRED_CSV_URL = "https://fred.stlouisfed.org/graph/fredgraph.csv?id=IRSTCB01IDM156N"

_PAGE_SIZE = 500
_BROWSER_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"
)


def fetch_idx_ratios(year: int, month: int, *, max_pages: int = 10) -> List[StockRatio]:
    """All per-stock ratios for ``year``/``month`` (monthly periodType), paginated.

    Requires ``curl_cffi`` (TLS impersonation clears Cloudflare — confirmed even from
    a datacenter IP, so CI works). Stops when a page returns fewer than a full page."""
    from curl_cffi import requests as cffi  # lazy: only the live path needs it

    records: List[StockRatio] = []
    with cffi.Session() as session:
        for page in range(1, max_pages + 1):
            params = {
                "urlName": "LINK_FINANCIAL_DATA_RATIO",
                "periodYear": year,
                "periodMonth": month,
                "periodType": "monthly",
                "isPrint": "False",
                "cumulative": "false",
                "pageSize": _PAGE_SIZE,
                "pageNumber": page,
            }
            resp = session.get(IDX_RATIO_URL, params=params, impersonate="chrome")
            resp.raise_for_status()
            rows = _extract_rows(resp.json())
            records.extend(StockRatio.from_api(r) for r in rows)
            if len(rows) < _PAGE_SIZE:
                break
    return records


def _extract_rows(payload) -> list:
    """Pull the list of row dicts out of the paginated wrapper. Tolerant of the exact
    envelope key (the response shape isn't formally documented): accepts a bare list,
    or a list under any of the common container keys."""
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        for key in ("data", "results", "Results", "Items", "items", "records", "rows"):
            value = payload.get(key)
            if isinstance(value, list):
                return value
            if isinstance(value, dict):
                inner = _extract_rows(value)
                if inner:
                    return inner
    return []


def fetch_bi_rate() -> Optional[BIRate]:
    """BI policy rate from bi.go.id (primary), falling back to FRED on any failure."""
    try:
        html = _get_text(BI_RATE_URL)
        bi = to_bi_rate(parse_bi_rate_html(html))
        if bi is not None:
            return bi
    except Exception:  # noqa: BLE001 — any live failure falls through to FRED
        pass
    return fetch_fred_rate()


def fetch_fred_rate() -> Optional[BIRate]:
    try:
        csv_text = _get_text(FRED_CSV_URL)
        return to_bi_rate(parse_fred_csv(csv_text))
    except Exception:  # noqa: BLE001
        return None


def _get_text(url: str) -> str:
    req = Request(url, headers={"User-Agent": _BROWSER_UA})
    with urlopen(req, timeout=30) as resp:  # noqa: S310 — fixed, trusted https URLs
        charset = resp.headers.get_content_charset() or "utf-8"
        return resp.read().decode(charset, errors="replace")
