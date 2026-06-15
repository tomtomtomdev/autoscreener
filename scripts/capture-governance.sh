#!/usr/bin/env bash
# Phase 0 capture for GovernanceService: fetch one live response per governance endpoint
# so the (currently UNVERIFIED) parsers in GovernanceService.swift can be confirmed and
# locked against real wire shapes. See idx-investing-research.md §4 / the GovernanceService
# header comment.
#
# Usage:
#   STOCKBIT_TOKEN="<bearer-without-the-word-Bearer>" ./scripts/capture-governance.sh [SYMBOL]
#   # SYMBOL defaults to TPIA
#
# Output: tools/governance-captures/<symbol>/<name>.json   (gitignored — these are raw
#         API payloads pulled with YOUR session; never commit them.)
#
# Notes:
#   - The insider family (majorholder / composition / ownership) is paywalled
#     (PAYWALL_FEATURE_INSIDER); a non-Pro token returns 401/402/403 there.
#   - The ownership (cross-holding) endpoint needs an `insider` id — copy one out of the
#     saved majorholder.json and pass it as the 2nd arg to re-run just that call.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYMBOL="${1:-TPIA}"
INSIDER_ID="${2:-}"
BASE="https://exodus.stockbit.com"
OUT="$ROOT/tools/governance-captures/$SYMBOL"

if [[ -z "${STOCKBIT_TOKEN:-}" ]]; then
  echo "error: set STOCKBIT_TOKEN to your bearer token (the value after 'Bearer ')." >&2
  exit 1
fi

mkdir -p "$OUT"

fetch() {  # name  path
  local name="$1" path="$2"
  echo "→ $name  ($path)"
  curl -sS -G "$BASE$path" \
    -H "authorization: Bearer $STOCKBIT_TOKEN" \
    -H "accept: application/json" \
    -o "$OUT/$name.json" \
    -w "    HTTP %{http_code}  →  $OUT/$name.json\n" || echo "    (request failed)"
  sleep 1.2   # mirror the in-app RequestThrottle cadence (1000–1500ms)
}

fetch "majorholder"  "/insider/company/majorholder?symbols=$SYMBOL&period_type=PERIOD_TYPE_1_YEAR&limit=30&page=1"
fetch "composition"  "/insider/shareholding/composition/companies/$SYMBOL"
fetch "corpaction"   "/corpaction/$SYMBOL"
fetch "subsidiary"   "/emitten-metadata/subsidiary/$SYMBOL"

if [[ -n "$INSIDER_ID" ]]; then
  fetch "ownership"  "/insider/majorholder/ownership?insider=$INSIDER_ID&symbol=$SYMBOL&page=1"
else
  echo "ℹ skipping ownership (cross-holding): pass an insider id as arg 2 once you have one"
  echo "   from majorholder.json, e.g.  ./scripts/capture-governance.sh $SYMBOL 15283"
fi

echo "done. Inspect $OUT/*.json, then update the parse* keypaths in"
echo "Autoscreener/Features/Governance/GovernanceService.swift and add a real fixture test."
