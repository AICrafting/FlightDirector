#!/usr/bin/env bash
# Unit tests for `flight --version` and `flight capabilities` (#254): a consumer
# (e.g. a UI driving the dispatcher) can tell which Flight it runs, and which
# features it supports, with no repo, config, token or network.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$REPO_ROOT/flight/scripts/flight"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail+1)); fi; }

VERSION="$(jq -r '.version' "$REPO_ROOT/flight/.claude-plugin/plugin.json")"
# Not a git repo, no .flightdirector/ — the probes must not need either.
cd "$SANDBOX"

out="$("$DISP" --version)"
check "--version prints the plugin name and version" "$([ "$out" = "flight $VERSION" ] && echo 1 || echo 0)" "$out"

out="$("$DISP" --version --json)"
check "--version --json is {plugin, version}" \
	"$(jq -e --arg v "$VERSION" '. == {plugin:"flight", version:$v}' <<<"$out" >/dev/null && echo 1 || echo 0)" "$out"

out="$("$DISP" capabilities --json)"
check "capabilities --json names the plugin and version" \
	"$(jq -e --arg v "$VERSION" '.plugin == "flight" and .version == $v' <<<"$out" >/dev/null && echo 1 || echo 0)" "$out"
check "capabilities --json lists string tokens, including the probes themselves" \
	"$(jq -e '(.capabilities | type == "array") and all(.capabilities[]; type == "string") and (.capabilities | index("version") != null) and (.capabilities | index("capabilities") != null)' <<<"$out" >/dev/null && echo 1 || echo 0)" "$out"
check "capability tokens are unique" \
	"$(jq -e '(.capabilities | length) == (.capabilities | unique | length)' <<<"$out" >/dev/null && echo 1 || echo 0)" "$out"

plain="$("$DISP" capabilities)"
check "capabilities without --json prints one token per line, same set" \
	"$([ "$plain" = "$(jq -r '.capabilities[]' <<<"$out")" ] && echo 1 || echo 0)" "$plain"

err="$("$DISP" --version --bogus 2>&1 >/dev/null || true)"
check "an unknown probe flag is a usage error" "$(grep -q 'usage: flight --version' <<<"$err" && echo 1 || echo 0)" "$err"

err="$("$DISP" 2>&1 >/dev/null || true)"
check "the usage line now mentions the probes" "$(grep -q 'flight --version' <<<"$err" && echo 1 || echo 0)" "$err"

[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
