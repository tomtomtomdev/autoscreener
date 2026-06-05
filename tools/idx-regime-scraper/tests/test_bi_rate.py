from pathlib import Path

from regime_scraper.bi_rate import (
    direction,
    parse_bi_rate_html,
    parse_date,
    parse_fred_csv,
    parse_rate,
    to_bi_rate,
)

FIXTURES = Path(__file__).parent / "fixtures"


def test_parse_rate_handles_comma_percent_and_rejects_implausible():
    assert parse_rate("4,75 %") == 4.75
    assert parse_rate("5.00%") == 5.00
    assert parse_rate("-") is None
    assert parse_rate("100") is None        # not a plausible policy rate


def test_parse_date_understands_iso_english_and_bahasa():
    assert parse_date("2026-01-15").isoformat() == "2026-01-15"
    assert parse_date("15 January 2026").isoformat() == "2026-01-15"
    assert parse_date("15 Januari 2026").isoformat() == "2026-01-15"
    assert parse_date("15/01/2026").isoformat() == "2026-01-15"
    assert parse_date("not a date") is None


def test_fred_csv_parses_and_drops_missing_dots():
    text = "observation_date,IRSTCB01IDM156N\n2025-11-01,5.75\n2025-12-01,.\n2026-01-01,4.75\n"
    assert parse_fred_csv(text) == [("2025-11-01", 5.75), ("2026-01-01", 4.75)]


def test_bi_html_sorts_newest_last_and_derives_a_cut():
    html = (FIXTURES / "bi_rate.html").read_text()
    bi = to_bi_rate(parse_bi_rate_html(html))
    assert bi is not None
    assert bi.value == 4.75
    assert bi.direction == "cut"           # 5.00 (Dec) → 4.75 (Jan)
    assert "2026" in bi.as_of


def test_direction_classifies_last_move():
    assert direction([("a", 4.5), ("b", 4.75)]) == "hike"
    assert direction([("a", 5.0), ("b", 4.75)]) == "cut"
    assert direction([("a", 5.0), ("b", 5.0)]) == "hold"
    assert direction([("a", 5.0)]) == "hold"


def test_fred_fallback_builds_bi_rate():
    text = "observation_date,IRSTCB01IDM156N\n2025-12-01,5.00\n2026-01-01,4.75\n"
    bi = to_bi_rate(parse_fred_csv(text))
    assert bi.value == 4.75
    assert bi.direction == "cut"
    assert bi.as_of == "2026-01-01"
