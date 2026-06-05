import pytest

from regime_scraper.aggregate import aggregate_index, filter_constituents, group_by_sector
from regime_scraper.models import StockRatio


def rec(code, sector, per, pbv, eq):
    return StockRatio(code=code, sector_code=sector, per=per, price_bv=pbv, equity=eq)


def test_cap_weighted_pe_pb_matches_hand_computation():
    # AAA: mcap=200, earnings=20 | BBB: mcap=200, earnings=10 | CCC (loss): pb only, mcap=80
    # DDD: negative equity → dropped entirely.
    recs = [rec("AAA", "FIN", 10, 2, 100), rec("BBB", "FIN", 20, 4, 50),
            rec("CCC", "ENE", -5, 1, 80), rec("DDD", "ENE", 15, 3, -10)]
    pe, pb = aggregate_index(recs)
    assert pb == pytest.approx(480 / 230)   # (200+200+80)/(100+50+80)
    assert pe == pytest.approx(400 / 30)    # (200+200)/(20+10)


def test_loss_makers_counted_in_pb_but_excluded_from_pe():
    pe, pb = aggregate_index([rec("X", "S", -3, 2, 100)])
    assert pe is None
    assert pb == pytest.approx(2.0)


def test_non_positive_equity_is_dropped():
    pe, pb = aggregate_index([rec("X", "S", 10, 2, -5), rec("Y", "S", 10, 2, 0)])
    assert pe is None
    assert pb is None


def test_extreme_per_is_winsorised():
    # B's absurd P/E is capped at max_per before weighting, so it can't dominate.
    recs = [rec("A", "S", 10, 2, 100), rec("B", "S", 100_000, 2, 100)]
    pe, _ = aggregate_index(recs, max_per=200)
    # earnings_A = 200/10 = 20 ; earnings_B = 200/200 = 1 ; PE = 400/21
    assert pe == pytest.approx(400 / 21)


def test_group_by_sector_and_filter_constituents_case_insensitive():
    recs = [rec("AAA", "FIN", 10, 2, 100), rec("BBB", "FIN", 20, 4, 50), rec("CCC", "ENE", -5, 1, 80)]
    groups = group_by_sector(recs)
    assert set(groups) == {"FIN", "ENE"}
    assert len(groups["FIN"]) == 2
    subset = filter_constituents(recs, ["aaa", "ccc"])
    assert {r.code for r in subset} == {"AAA", "CCC"}
