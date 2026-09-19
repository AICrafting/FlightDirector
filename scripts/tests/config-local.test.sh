#!/usr/bin/env bash
# Unit tests for the optional, gitignored `.flightdirector/config.local.json` (#129):
# it is recursively merged over `config.json` for every READ, while `reconcile`
# keeps writing the tracked file only.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$REPO_ROOT/flight/scripts/flight"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail+1)); fi; }

[ -x "$DISP" ]

BASE='{"code":{"backend":"forgejo","owner":"acme","repo":"widget","stages":[{"name":"develop"},{"name":"main"}],"promptLog":{"enabled":false}}}'
mkrepo() { # $1 = name → prints path; tracked config.json written, git initialised
	local r="$SANDBOX/$1"; mkdir -p "$r/.flightdirector"; git -C "$r" init -q
	printf '%s\n' "$BASE" >"$r/.flightdirector/config.json"
	printf '%s\n' "$r"
}

# --- 1. no local file → identical behaviour, silent ---------------------------
R="$(mkrepo none)"
out="$(cd "$R" && "$DISP" config '.code.owner' 2>"$R/err")"
check "no config.local.json: reads config.json as before" "$([ "$out" = acme ] && echo 1 || echo 0)" "$out"
check "no config.local.json: nothing on stderr" "$([ ! -s "$R/err" ] && echo 1 || echo 0)" "$(cat "$R/err")"

# --- 2. nested override: only the keys present in the local file change --------
R="$(mkrepo nested)"
echo '{"code":{"owner":"me","promptLog":{"enabled":true}}}' >"$R/.flightdirector/config.local.json"
out="$(cd "$R" && "$DISP" config '.code | [.owner, .repo, .backend, .promptLog.enabled] | tojson' 2>"$R/err")"
check "local scalar overrides the tracked value" "$(grep -q '"me"' <<<"$out" && echo 1 || echo 0)" "$out"
check "sibling keys the local file omits survive" "$(grep -q '"widget"' <<<"$out" && grep -q '"forgejo"' <<<"$out" && echo 1 || echo 0)" "$out"
check "nested objects merge key by key" "$(grep -q 'true' <<<"$out" && echo 1 || echo 0)" "$out"
check "a valid local file is silent" "$([ ! -s "$R/err" ] && echo 1 || echo 0)" "$(cat "$R/err")"

# --- 3. arrays replace, they do not patch --------------------------------------
R="$(mkrepo arrays)"
echo '{"code":{"stages":[{"name":"trunk"}]}}' >"$R/.flightdirector/config.local.json"
out="$(cd "$R" && "$DISP" config '[.code.stages[].name] | tojson' 2>/dev/null)"
check "a local array replaces the tracked array wholesale" "$([ "$out" = '["trunk"]' ] && echo 1 || echo 0)" "$out"

# --- 4. reconcile writes the TRACKED file and never bakes local values in -----
R="$(mkrepo reconcile)"
echo '{"code":{"owner":"me"}}' >"$R/.flightdirector/config.local.json"
(cd "$R" && "$DISP" reconcile --harness claude >/dev/null 2>&1)
check "reconcile stamps the tracked config.json" \
	"$([ -n "$(jq -r '.harnesses.claude.plugins.flight.reconciledWith // empty' "$R/.flightdirector/config.json")" ] && echo 1 || echo 0)"
check "reconcile does not copy local overrides into the tracked file" \
	"$([ "$(jq -r '.code.owner' "$R/.flightdirector/config.json")" = acme ] && echo 1 || echo 0)"
check "reconcile leaves config.local.json untouched" \
	"$([ "$(cat "$R/.flightdirector/config.local.json")" = '{"code":{"owner":"me"}}' ] && echo 1 || echo 0)"
out="$(cd "$R" && "$DISP" config '.code.owner' 2>/dev/null)"
check "after reconcile the merged view still applies" "$([ "$out" = me ] && echo 1 || echo 0)" "$out"

# --- 5. invalid local JSON is a clear error, not a silent fallback -----------
R="$(mkrepo invalid)"
echo '{"code":' >"$R/.flightdirector/config.local.json"
if (cd "$R" && "$DISP" config '.code.owner' >/dev/null 2>"$R/err"); then rc=0; else rc=$?; fi
check "invalid config.local.json exits non-zero" "$([ "$rc" != 0 ] && echo 1 || echo 0)"
check "the error names config.local.json" "$(grep -q 'config\.local\.json' "$R/err" && echo 1 || echo 0)" "$(cat "$R/err")"

# --- 6. a local file without a tracked config.json is not a config ------------
R="$SANDBOX/orphan"; mkdir -p "$R/.flightdirector"; git -C "$R" init -q
echo '{"code":{"backend":"forgejo"}}' >"$R/.flightdirector/config.local.json"
if (cd "$R" && "$DISP" config '.code' >/dev/null 2>"$R/err"); then rc=0; else rc=$?; fi
check "config.local.json alone still reports the missing config.json" \
	"$([ "$rc" != 0 ] && grep -q '\.flightdirector/config\.json' "$R/err" && echo 1 || echo 0)" "$(cat "$R/err")"

# --- 7. a TRACKED config.local.json gets a loud warning ------------------------
R="$(mkrepo tracked)"
echo '{"code":{"owner":"me"}}' >"$R/.flightdirector/config.local.json"
git -C "$R" add .flightdirector/config.local.json
out="$(cd "$R" && "$DISP" config '.code.owner' 2>"$R/err")"
check "a tracked config.local.json still merges" "$([ "$out" = me ] && echo 1 || echo 0)" "$out"
check "…but warns that it should be gitignored" \
	"$(grep -qi 'warning' "$R/err" && grep -q 'config\.local\.json' "$R/err" && grep -qi 'gitignore' "$R/err" && echo 1 || echo 0)" "$(cat "$R/err")"

# --- 8. legacy .lightspeed/ home honours its own config.local.json ------------
R="$SANDBOX/legacy"; mkdir -p "$R/.lightspeed"; git -C "$R" init -q
printf '%s\n' "$BASE" >"$R/.lightspeed/config.json"
echo '{"code":{"owner":"legacy-me"}}' >"$R/.lightspeed/config.local.json"
out="$(cd "$R" && "$DISP" config '.code.owner' 2>/dev/null)"
check "legacy .lightspeed/config.local.json is merged when that home is in use" "$([ "$out" = legacy-me ] && echo 1 || echo 0)" "$out"

# --- 9. no merged temp file is left behind, including on an exec'd verb -------
R="$(mkrepo tmp)"; mkdir -p "$R/tmp"
echo '{"code":{"owner":"me"}}' >"$R/.flightdirector/config.local.json"
(cd "$R" && TMPDIR="$R/tmp" "$DISP" config '.code.owner' >/dev/null 2>&1)
(cd "$R" && TMPDIR="$R/tmp" "$DISP" prompt-log summary --session nope >/dev/null 2>&1 || true)
(cd "$R" && TMPDIR="$R/tmp" "$DISP" reconcile --harness codex >/dev/null 2>&1 || true)
check "no merged-config temp files are leaked" "$([ -z "$(ls -A "$R/tmp")" ] && echo 1 || echo 0)" "$(ls -A "$R/tmp")"

# --- 10. a linked worktree sees the main checkout's local file -----------------
R="$(mkrepo wt)"
echo '{"code":{"owner":"wt-me"}}' >"$R/.flightdirector/config.local.json"
git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$R" worktree add -q "$R/.worktrees/x" -b x
out="$(cd "$R/.worktrees/x" && "$DISP" config '.code.owner' 2>/dev/null)"
check "linked worktree reads the main checkout's config.local.json" "$([ "$out" = wt-me ] && echo 1 || echo 0)" "$out"

# Summary: plain when nothing failed, red when something did (#123).
[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
