#!/usr/bin/env bash
# Unit tests for `flight config worker-model` (#236): code.queueBatches.defaultModel
# as a string or an ordered preference list, resolved against the running harness.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$REPO_ROOT/flight/scripts/flight"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail+1)); fi; }

R="$SANDBOX/repo"; mkdir -p "$R/.flightdirector"; git -C "$R" init -q
setmodel() { # $1 = JSON value for defaultModel, or empty to leave the key out
	if [ -n "$1" ]; then
		printf '{"code":{"backend":"forgejo","queueBatches":{"defaultModel":%s}}}\n' "$1" >"$R/.flightdirector/config.json"
	else
		printf '{"code":{"backend":"forgejo"}}\n' >"$R/.flightdirector/config.json"
	fi
}
resolve() { (cd "$R" && "$DISP" config worker-model --harness "$1"); }
first_use() { resolve "$1" | awk -F'\t' '$2 == "use" { print $1; exit }'; }

# --- a plain string is a one-item list ----------------------------------------
setmodel '"opus"'
out="$(resolve claude)"
check "string: one line" "$([ "$(wc -l <<<"$out")" -eq 1 ] && echo 1 || echo 0)" "$out"
check "string: usable in its own harness" "$([ "$(first_use claude)" = opus ] && echo 1 || echo 0)" "$out"
out="$(resolve codex)"
check "string: skipped in the other harness, with the reason" \
	"$([ "$out" = "$(printf 'opus\tskip\tclaude model, not available in codex')" ] && echo 1 || echo 0)" "$out"
check "string: nothing usable in the other harness" "$([ -z "$(first_use codex)" ] && echo 1 || echo 0)"

# --- an ordered list: first entry the harness can dispatch --------------------
setmodel '["opus","gpt-5.6-sol","sonnet"]'
check "list: claude picks the first claude entry" "$([ "$(first_use claude)" = opus ] && echo 1 || echo 0)"
check "list: codex skips opus and picks gpt-5.6-sol" "$([ "$(first_use codex)" = gpt-5.6-sol ] && echo 1 || echo 0)"
out="$(resolve codex)"
check "list: order is preserved, every entry reported" \
	"$([ "$(cut -f1 <<<"$out" | tr '\n' ' ')" = 'opus gpt-5.6-sol sonnet ' ] && echo 1 || echo 0)" "$out"
check "list: later same-harness entries stay as fallbacks" \
	"$([ "$(resolve claude | awk -F'\t' '$2 == "use" { print $1 }' | tr '\n' ' ')" = 'opus sonnet ' ] && echo 1 || echo 0)"

# --- recognised forms -----------------------------------------------------------
setmodel '["claude-fable-5-1","us.anthropic.claude-sonnet-4-5","haiku","sol","openai/gpt-5.6-terra","o4-mini","codex-mini-latest"]'
out="$(resolve claude)"
check "claude ids, routing prefixes and aliases are claude's" \
	"$([ "$(awk -F'\t' '$2 == "use" { print $1 }' <<<"$out" | tr '\n' ' ')" = 'claude-fable-5-1 us.anthropic.claude-sonnet-4-5 haiku ' ] && echo 1 || echo 0)" "$out"
out="$(resolve codex)"
check "gpt ids, codenames, o-series and codex ids are codex's" \
	"$([ "$(awk -F'\t' '$2 == "use" { print $1 }' <<<"$out" | tr '\n' ' ')" = 'sol openai/gpt-5.6-terra o4-mini codex-mini-latest ' ] && echo 1 || echo 0)" "$out"

# --- unknown ids are tried, not skipped ------------------------------------------
setmodel '["acme-large"]'
check "unrecognised id is left for the harness to try" \
	"$([ "$(first_use claude)" = acme-large ] && [ "$(first_use codex)" = acme-large ] && echo 1 || echo 0)"

# --- absent key keeps the historical default -----------------------------------
setmodel ''
check "absent key: claude falls back to sonnet" "$([ "$(first_use claude)" = sonnet ] && echo 1 || echo 0)"
check "absent key: codex falls back to luna" "$([ "$(first_use codex)" = luna ] && echo 1 || echo 0)"

# --- empty list and bad values ---------------------------------------------------
setmodel '[]'
out="$(resolve claude)"
check "empty list: no lines" "$([ -z "$out" ] && echo 1 || echo 0)" "$out"
setmodel '{"claude":["opus"]}'
if (cd "$R" && "$DISP" config worker-model --harness claude) >/dev/null 2>"$SANDBOX/err"; then
	check "object value is rejected" 0
else
	check "object value is rejected with a clear message" "$(grep -q 'must be a model name or an array' "$SANDBOX/err" && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
fi
setmodel '"opus"'
if (cd "$R" && "$DISP" config worker-model --harness gemini) >/dev/null 2>&1; then
	check "unknown harness is rejected" 0
else
	check "unknown harness is rejected" 1
fi

# --- config.local.json can override the list per machine -----------------------
setmodel '"opus"'
echo '{"code":{"queueBatches":{"defaultModel":["gpt-5.6-sol"]}}}' >"$R/.flightdirector/config.local.json"
check "a local override replaces the list" "$([ "$(first_use codex)" = gpt-5.6-sol ] && echo 1 || echo 0)"
rm -f "$R/.flightdirector/config.local.json"

# --- ordinary jq reads still work -------------------------------------------------
check "plain \`config <filter>\` is unaffected" "$([ "$(cd "$R" && "$DISP" config '.code.backend')" = forgejo ] && echo 1 || echo 0)"

[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
