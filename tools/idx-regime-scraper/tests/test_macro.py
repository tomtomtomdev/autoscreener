from regime_scraper.bi_rate import parse_rate
from regime_scraper.macro import (
    parse_fred_series,
    parse_fred_value,
    to_macro_series,
    trend,
)


def test_parse_fred_value_is_permissive_about_magnitude():
    # The broad-dollar index trades around 120 — parse_rate's policy-rate
    # plausibility bound (0 < x < 50) would wrongly reject it, which is exactly
    # why the macro series needs its own value parser.
    assert parse_fred_value("121.5") == 121.5
    assert parse_rate("121.5") is None       # contrast: rejected by the rate bound
    assert parse_fred_value("4.30") == 4.30
    assert parse_fred_value(".") is None     # FRED's missing marker
    assert parse_fred_value("") is None


def test_parse_fred_series_keeps_dated_values_and_drops_missing():
    text = (
        "observation_date,DGS10\n"
        "2026-06-01,4.30\n"
        "2026-06-02,.\n"
        "2026-06-03,4.35\n"
    )
    assert parse_fred_series(text) == [("2026-06-01", 4.30), ("2026-06-03", 4.35)]


def test_trend_classifies_over_a_lookback_window():
    rising = [("a", 4.0), ("b", 4.1), ("c", 4.3)]
    falling = [("a", 4.3), ("b", 4.1), ("c", 4.0)]
    flat = [("a", 4.2), ("b", 4.2)]
    assert trend(rising, lookback=2) == "up"
    assert trend(falling, lookback=2) == "down"
    assert trend(flat) == "flat"
    assert trend([("a", 4.0)]) == "flat"      # too short to have a direction
    # lookback longer than the series clamps to the oldest available observation
    assert trend(rising, lookback=99) == "up"


def test_to_macro_series_takes_latest_value_trend_and_iso_date():
    text = (
        "observation_date,DGS10\n"
        "2026-06-01,4.30\n"
        "2026-06-03,4.35\n"
    )
    series = to_macro_series(parse_fred_series(text))
    assert series is not None
    assert series.value == 4.35
    assert series.trend == "up"
    assert series.as_of == "2026-06-03"
    assert series.to_dict() == {"value": 4.35, "trend": "up", "asOf": "2026-06-03"}


def test_to_macro_series_none_on_empty():
    assert to_macro_series([]) is None
