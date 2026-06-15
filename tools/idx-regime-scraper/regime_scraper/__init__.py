"""IDX regime scraper — builds the static ``regime.json`` the macOS/iOS app reads.

See ``idx-regime-data-research.md`` §4–§6 for the data sources and the plan. The
package is split into **pure** logic (``aggregate``, ``percentile``, ``bi_rate``
parsers, ``build``) that is unit-tested against saved fixtures, and thin **live**
HTTP in ``sources`` (lazy ``curl_cffi`` import) that is exercised only by the real
GitHub Actions run.
"""
