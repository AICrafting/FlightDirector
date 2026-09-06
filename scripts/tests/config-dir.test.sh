#!/usr/bin/env bash
# Unit tests for the dispatcher's config-directory resolution during the
# lightspeed → flight rename: `.flightdirector/` is the home, legacy
# `.lightspeed/` still works (with a deprecation notice), and the old
# `lightspeed` PATH entrypoint still delegates.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$REPO_ROOT/flight/scripts/flight"
LEGACY_BIN="$REPO_ROOT/flight/bin/lightspeed"
NEW_BIN="$REPO_ROOT/flight/bin/flight"
BM="$REPO_ROOT/flight/scripts/batch-manifest"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0; fail=0
check() {
	if [ "$2" = 1 ]; then pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
	else fail=$((fail + 1)); printf '  ✗ %s\n' "$1"; fi
}

[ -x "$DISP" ]; [ -x "$LEGACY_BIN" ]; [ -x "$NEW_BIN" ]

# --- 1. new home only -------------------------------------------------------
R="$SANDBOX/new"; mkdir -p "$R/.flightdirector"; git -C "$R" init -q
echo '{"code":{"backend":"forgejo","stages":[{"name":"develop"}]}}' >"$R/.flightdirector/config.json"
out="$(cd "$R" && "$DISP" config '.code.stages[0].name' 2>"$R/err")"
check "reads .flightdirector/config.json" "$([ "$out" = develop ] && echo 1 || echo 0)"
check "no deprecation notice for the new home" "$([ ! -s "$R/err" ] && echo 1 || echo 0)"

# --- 2. legacy only ---------------------------------------------------------
R="$SANDBOX/legacy"; mkdir -p "$R/.lightspeed"; git -C "$R" init -q
echo '{"code":{"backend":"forgejo","stages":[{"name":"trunk"}]}}' >"$R/.lightspeed/config.json"
out="$(cd "$R" && "$DISP" config '.code.stages[0].name' 2>"$R/err")"
check "falls back to legacy .lightspeed/config.json" "$([ "$out" = trunk ] && echo 1 || echo 0)"
check "legacy fallback prints a deprecation notice naming .flightdirector/" \
	"$(grep -q 'flightdirector' "$R/err" && grep -qi 'deprecat' "$R/err" && echo 1 || echo 0)"
(cd "$R" && "$DISP" reconcile --harness claude 2>/dev/null)
check "reconcile writes into the legacy dir when that is the one in use" \
	"$([ -n "$(jq -r '.harnesses.claude.plugins.flight.reconciledWith // empty' "$R/.lightspeed/config.json")" ] && echo 1 || echo 0)"

# --- 3. both present → new wins, no notice ----------------------------------
R="$SANDBOX/both"; mkdir -p "$R/.flightdirector" "$R/.lightspeed"; git -C "$R" init -q
echo '{"code":{"backend":"forgejo","stages":[{"name":"new"}]}}' >"$R/.flightdirector/config.json"
echo '{"code":{"backend":"forgejo","stages":[{"name":"old"}]}}' >"$R/.lightspeed/config.json"
out="$(cd "$R" && "$DISP" config '.code.stages[0].name' 2>"$R/err")"
check "new home wins when both exist" "$([ "$out" = new ] && echo 1 || echo 0)"
check "no notice when the new home exists" "$([ ! -s "$R/err" ] && echo 1 || echo 0)"

# --- 4. neither → error names the new home ----------------------------------
R="$SANDBOX/none"; mkdir -p "$R"; git -C "$R" init -q
if (cd "$R" && "$DISP" config '.code' 2>"$R/err"); then
	check "missing config is an error" 0
else
	check "missing config is an error" 1
fi
check "missing-config error names .flightdirector/config.json" \
	"$(grep -q '\.flightdirector/config\.json' "$R/err" && echo 1 || echo 0)"

# --- 5. worktree resolves the MAIN checkout's config, either home -----------
R="$SANDBOX/wt"; mkdir -p "$R/.flightdirector"; git -C "$R" init -q
echo '{"code":{"backend":"forgejo","stages":[{"name":"main-cfg"}]}}' >"$R/.flightdirector/config.json"
git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$R" worktree add -q "$R/.worktrees/x" -b x
out="$(cd "$R/.worktrees/x" && "$DISP" config '.code.stages[0].name' 2>/dev/null)"
check "linked worktree reads the main checkout's .flightdirector/" "$([ "$out" = main-cfg ] && echo 1 || echo 0)"

# --- 6. legacy `lightspeed` entrypoint delegates with a notice --------------
R="$SANDBOX/shim"; mkdir -p "$R/.flightdirector"; git -C "$R" init -q
echo '{"code":{"backend":"forgejo","stages":[{"name":"via-shim"}]}}' >"$R/.flightdirector/config.json"
out="$(cd "$R" && "$LEGACY_BIN" config '.code.stages[0].name' 2>"$R/err")"
check "bin/lightspeed still delegates to the dispatcher" "$([ "$out" = via-shim ] && echo 1 || echo 0)"
check "bin/lightspeed prints a deprecation notice naming flight" \
	"$(grep -qi 'deprecat' "$R/err" && grep -q 'flight' "$R/err" && echo 1 || echo 0)"
out="$(cd "$R" && "$NEW_BIN" config '.code.stages[0].name' 2>"$R/err")"
check "bin/flight delegates silently" "$([ "$out" = via-shim ] && [ ! -s "$R/err" ] && echo 1 || echo 0)"

# --- 7. batch-manifest follows the same resolution --------------------------
R="$SANDBOX/bm-new"; mkdir -p "$R/.flightdirector"; git -C "$R" init -q
echo '{}' >"$R/.flightdirector/config.json"
(cd "$R" && "$BM" write --run-id R1 --zone z --issues "1 2" >/dev/null 2>&1)
check "batch-manifest writes under .flightdirector/batches/ for the new home" \
	"$([ -f "$R/.flightdirector/batches/R1.json" ] && echo 1 || echo 0)"
R="$SANDBOX/bm-legacy"; mkdir -p "$R/.lightspeed"; git -C "$R" init -q
echo '{}' >"$R/.lightspeed/config.json"
(cd "$R" && "$BM" write --run-id R1 --zone z --issues "1 2" >/dev/null 2>&1)
check "batch-manifest writes under legacy .lightspeed/batches/ when that is in use" \
	"$([ -f "$R/.lightspeed/batches/R1.json" ] && echo 1 || echo 0)"

printf 'Passed: %d  Failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
