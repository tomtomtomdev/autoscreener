from regime_scraper.percentile import percentile_rank


def test_rank_is_fraction_at_or_below():
    assert percentile_rank(12, [10, 11, 12, 13, 14]) == 0.6


def test_min_and_max_of_series():
    assert percentile_rank(14, [10, 11, 12, 13, 14]) == 1.0
    assert percentile_rank(10, [10, 11, 12, 13, 14]) == 0.2


def test_ignores_none_value_and_empty_history():
    assert percentile_rank(None, [1, 2]) is None
    assert percentile_rank(5, []) is None
    assert percentile_rank(5, [None, None]) is None


def test_drops_none_entries_from_history():
    # [1, 3] after dropping None; values <= 2 → just 1 → 0.5
    assert percentile_rank(2, [1, None, 3]) == 0.5
