#!/usr/bin/env bash
#
# Local runner for the IDX regime scraper.
#
# WHY THIS EXISTS: Cloudflare now blocks GitHub Actions' datacenter IPs (every
# fetch 403s in CI), but a Jakarta residential IP clears the same TLS-fingerprint
# gate. So the monthly job runs here instead of in .github/workflows/idx-regime.yml.
# This mirrors that workflow exactly: build dist/regime.json (+ regime-history.json)
# and publish them to the `data` branch, where the app fetches the raw URL.
#
# Usage:
#   ./run-local.sh [BACKFILL]   # BACKFILL = months of history to seed (default 0)
#
# Git auth goes over HTTPS via the `gh` credential helper (SSH keys are not always
# available to a launchd session). It NEVER touches your working tree — publishing
# happens in a throwaway worktree.
set -euo pipefail

BACKFILL="${1:-0}"
REPO="/Users/tommyyohanes/autoscreener"
SCRAPER="$REPO/tools/idx-regime-scraper"
DIST="$SCRAPER/dist"
VENV="$SCRAPER/.venv"
HTTPS_URL="https://github.com/tomtomtomdev/autoscreener.git"
TMPROOT="$(mktemp -d)"
WORKTREE="$TMPROOT/data-branch"

cleanup() {
  git -C "$REPO" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

log() { echo "[$(date -u +%FT%TZ)] $*"; }

data_branch_exists() { [ -n "$(git ls-remote --heads "$HTTPS_URL" data)" ]; }

log "=== regime scraper local run (backfill=$BACKFILL) ==="

# 1. venv + deps (cheap to re-run; pip is a no-op when satisfied)
cd "$SCRAPER"
[ -x "$VENV/bin/python" ] || python3 -m venv "$VENV"
"$VENV/bin/pip" install -q --upgrade pip
"$VENV/bin/pip" install -q -r requirements.txt

# 2. restore prior history so the build upserts onto it instead of starting empty
mkdir -p "$DIST"
if data_branch_exists; then
  git -C "$REPO" fetch -q "$HTTPS_URL" data
  git -C "$REPO" show FETCH_HEAD:regime-history.json > "$DIST/regime-history.json" 2>/dev/null \
    && log "restored prior history ($(grep -c '"period"' "$DIST/regime-history.json" || echo 0) points)" \
    || log "data branch has no regime-history.json yet"
else
  log "no data branch yet (first run) — building fresh history"
fi

# 3. build (the only step that needs the clean IP)
"$VENV/bin/python" -m regime_scraper --backfill "$BACKFILL"

# 4. publish to the data branch in an isolated worktree
cd "$REPO"
if data_branch_exists; then
  git fetch -q "$HTTPS_URL" data
  git worktree add -q "$WORKTREE" FETCH_HEAD
  git -C "$WORKTREE" checkout -q -B data
else
  git worktree add -q --detach "$WORKTREE" HEAD
  git -C "$WORKTREE" checkout -q --orphan data
  git -C "$WORKTREE" rm -rq . >/dev/null 2>&1 || true
fi
cp "$DIST/regime.json" "$DIST/regime-history.json" "$WORKTREE/"
git -C "$WORKTREE" add regime.json regime-history.json
if git -C "$WORKTREE" commit -q -m "data: regime snapshot $(date -u +%F)"; then
  git -C "$WORKTREE" push -q "$HTTPS_URL" HEAD:data
  log "published regime.json + regime-history.json to data branch"
else
  log "no changes to publish"
fi

log "=== done ==="
