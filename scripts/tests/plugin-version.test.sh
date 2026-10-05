#!/usr/bin/env bash
# Unit tests for flight/scripts/plugin-version.sh, the engine behind `/flight:version`
# (FJ-257): it reports the plugin the harness loaded — read from that root's own manifest —
# and the `flight` dispatcher on PATH, and says so when the two disagree or there is no
# dispatcher. Each case runs against a fake plugin root in a sandbox and a stub `flight`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/flight/scripts/plugin-version.sh"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail+1)); fi; }
has() { grep -qF -- "$2" <<<"$1" && echo 1 || echo 0; }
hasnt() { grep -qF -- "$2" <<<"$1" && echo 0 || echo 1; }

# A fake plugin root in the versioned-cache layout, holding a copy of the script so the
# default root (the script's parent) is exercised too.
make_root() {   # <dir> <version> [manifest dir]
	mkdir -p "$1/${3:-.claude-plugin}" "$1/scripts"
	printf '{"name":"flight","version":"%s"}\n' "$2" >"$1/${3:-.claude-plugin}/plugin.json"
	cp "$SCRIPT" "$1/scripts/plugin-version.sh"
}
CACHE_ROOT="$SANDBOX/home/.claude/plugins/cache/flightdirector-dev/flight/1.2.3"
make_root "$CACHE_ROOT" 1.2.3

# A stub dispatcher, so PATH holds a `flight` of a version the test chooses. The rest of PATH
# is kept for jq/awk/etc.; a sandbox dir with no `flight` stands in for "not on PATH" by
# filtering any real one out.
STUB="$SANDBOX/stub"; mkdir -p "$STUB"
stub_flight() {   # <version>
	# shellcheck disable=SC2016 # the stub's own $1, expanded when the stub runs
	printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && echo "flight %s"\n' "$1" >"$STUB/flight"
	chmod +x "$STUB/flight"
}
BASE_PATH=""
IFS=: read -ra parts <<<"$PATH"
for p in "${parts[@]}"; do [ -x "$p/flight" ] || BASE_PATH="${BASE_PATH:+$BASE_PATH:}$p"; done

run() { PATH="$STUB:$BASE_PATH" bash "$CACHE_ROOT/scripts/plugin-version.sh" "$@" 2>&1; }

printf '\033[1m── matching versions ──\033[0m\n'
stub_flight 1.2.3
out="$(run)"
check "the first line is the loaded plugin's name and version" "$([ "$(head -n1 <<<"$out")" = "flight 1.2.3" ] && echo 1 || echo 0)" "$out"
check "the plugin root defaults to the script's parent" "$(has "$out" "plugin root: $CACHE_ROOT")" "$out"
check "the dispatcher on PATH is reported with its version and path" "$(has "$out" "dispatcher:  flight 1.2.3 ($STUB/flight)")" "$out"
check "matching versions print no note" "$(hasnt "$out" "note:")" "$out"
out="$(run --json)"
check "--json reports matches:true and a null note" \
	"$(jq -e '.matches == true and .note == null and .version == "1.2.3" and .dispatcher.version == "1.2.3"' <<<"$out" >/dev/null && echo 1 || echo 0)" "$out"

printf '\033[1m── differing versions ──\033[0m\n'
stub_flight 9.9.9
out="$(run)"
check "the plugin version still comes from the loaded manifest, not the CLI" "$([ "$(head -n1 <<<"$out")" = "flight 1.2.3" ] && echo 1 || echo 0)" "$out"
check "a differing dispatcher gets a note naming both versions" "$(has "$out" "note: the \`flight\` on PATH (9.9.9) differs from the loaded plugin (1.2.3)")" "$out"
out="$(run --json)"
check "--json reports matches:false with the note" \
	"$(jq -e '.matches == false and (.note | test("differs")) and .dispatcher.version == "9.9.9"' <<<"$out" >/dev/null && echo 1 || echo 0)" "$out"

printf '\033[1m── no flight on PATH ──\033[0m\n'
rm -f "$STUB/flight"
out="$(run)"
check "a missing dispatcher is reported as not on PATH" "$(has "$out" "dispatcher:  not on PATH")" "$out"
check "and gets its own note" "$(has "$out" "note: no \`flight\` dispatcher on PATH")" "$out"
out="$(run --json)"
check "--json reports a null dispatcher and matches:false" \
	"$(jq -e '.dispatcher == null and .matches == false' <<<"$out" >/dev/null && echo 1 || echo 0)" "$out"

printf '\033[1m── install derivation ──\033[0m\n'
stub_flight 1.2.3
out="$(run)"
check "a versioned cache root names <plugin>@<marketplace>" "$(has "$out" "install:     flight@flightdirector-dev")" "$out"

MKT_ROOT="$SANDBOX/home/.claude/plugins/marketplaces/flightdirector/flight"
make_root "$MKT_ROOT" 1.2.3
out="$(PATH="$STUB:$BASE_PATH" bash "$SCRIPT" --root "$MKT_ROOT" 2>&1)"
check "a marketplace checkout root names <plugin>@<marketplace>" "$(has "$out" "install:     flight@flightdirector")" "$out"
check "--root overrides the default root" "$(has "$out" "plugin root: $MKT_ROOT")" "$out"

DEV_ROOT="$SANDBOX/src/flightdirector/flight"
make_root "$DEV_ROOT" 1.2.3
out="$(PATH="$STUB:$BASE_PATH" bash "$SCRIPT" --root "$DEV_ROOT" 2>&1)"
check "any other layout is unknown, never guessed" "$(has "$out" "install:     unknown")" "$out"

CODEX_ROOT="$SANDBOX/codex/flight"
make_root "$CODEX_ROOT" 1.2.3 .codex-plugin
out="$(PATH="$STUB:$BASE_PATH" bash "$SCRIPT" --root "$CODEX_ROOT" 2>&1)"
check "a root with only the Codex manifest is read from it" "$([ "$(head -n1 <<<"$out")" = "flight 1.2.3" ] && echo 1 || echo 0)" "$out"

out="$(PATH="$STUB:$BASE_PATH" bash "$SCRIPT" --root "$SANDBOX/nowhere" 2>&1 || true)"
check "a missing root is an error" "$(has "$out" "no such plugin root")" "$out"
mkdir -p "$SANDBOX/empty"
rc=0; out="$(PATH="$STUB:$BASE_PATH" bash "$SCRIPT" --root "$SANDBOX/empty" 2>&1)" || rc=$?
check "a root with no manifest fails rather than guessing" "$([ "$rc" -ne 0 ] && [ "$(has "$out" "no plugin manifest")" = 1 ] && echo 1 || echo 0)" "$out"

printf '\033[1m── the real plugin ──\033[0m\n'
VERSION="$(jq -r '.version' "$REPO_ROOT/flight/.claude-plugin/plugin.json")"
out="$(PATH="$STUB:$BASE_PATH" bash "$SCRIPT" 2>&1)"
check "this repo's plugin reports its own manifest version" "$([ "$(head -n1 <<<"$out")" = "flight $VERSION" ] && echo 1 || echo 0)" "$out"
CMD="$REPO_ROOT/flight/commands/version.md"
# shellcheck disable=SC2016 # a literal ${CLAUDE_PLUGIN_ROOT}, as the command file spells it
check "the /flight:version command runs the script from the plugin root" \
	"$(grep -qF '${CLAUDE_PLUGIN_ROOT}/scripts/plugin-version.sh' "$CMD" && echo 1 || echo 0)"

[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
