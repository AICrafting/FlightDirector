#!/usr/bin/env bash
# Self-test for scripts/bump-version.sh — runs it against a throwaway sandbox
# repo (two plugins) and asserts it bumps only the named plugin's version
# fields and rolls only that plugin's changelog.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUMP="$REPO_ROOT/scripts/bump-version.sh"

pass=0
fail=0

check() {
	local name="$1" cond="$2"
	if [ "$cond" = "1" ]; then
		printf '\033[0;32m  ✓ %s\033[0m\n' "$name"
		pass=$((pass + 1))
	else
		printf '\033[0;31m  ✗ %s\033[0m\n' "$name"
		fail=$((fail + 1))
	fi
}

# Read a top-level (or first) "version": "X" out of a JSON file with grep/sed.
json_version() {
	grep -m1 '"version"' "$1" | sed 's/.*"version": *"\([^"]*\)".*/\1/'
}

# --- build a throwaway sandbox repo with two plugins ------------------------
make_sandbox() {
	local root="$1"
	mkdir -p "$root/lightspeed/.claude-plugin" "$root/lightspeed/.codex-plugin" \
		"$root/other/.claude-plugin" "$root/.claude-plugin"

	cat >"$root/lightspeed/.claude-plugin/plugin.json" <<'JSON'
{
  "name": "lightspeed",
  "version": "1.2.3",
  "description": "test"
}
JSON
	cat >"$root/lightspeed/.codex-plugin/plugin.json" <<'JSON'
{
  "name": "lightspeed",
  "version": "1.2.3",
  "description": "test",
  "skills": "./skills/"
}
JSON

	cat >"$root/other/.claude-plugin/plugin.json" <<'JSON'
{
  "name": "other",
  "version": "9.9.9",
  "description": "test"
}
JSON

	cat >"$root/.claude-plugin/marketplace.json" <<'JSON'
{
  "name": "cerebralgardens",
  "plugins": [
    {
      "name": "lightspeed",
      "source": "./lightspeed",
      "version": "1.2.3",
      "keywords": ["forgejo", "github"]
    },
    {
      "name": "other",
      "source": "./other",
      "version": "9.9.9"
    }
  ]
}
JSON

	cat >"$root/lightspeed/CHANGELOG.md" <<'MD'
# Changelog

## [Unreleased]

### Added
- A shiny new thing.

## [1.2.3] - 2026-01-01

### Added
- The old thing.
MD

	cat >"$root/other/CHANGELOG.md" <<'MD'
# Changelog

## [Unreleased]

_Nothing yet._

## [9.9.9] - 2026-01-01

### Added
- Other's old thing.
MD
}

TODAY="$(date -u +%F)"

# --- happy path: bump only lightspeed ---------------------------------------
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
make_sandbox "$SANDBOX"

BUMP_VERSION_ROOT="$SANDBOX" "$BUMP" lightspeed 1.3.0 >/dev/null

check "lightspeed plugin.json bumped" \
	"$([ "$(json_version "$SANDBOX/lightspeed/.claude-plugin/plugin.json")" = "1.3.0" ] && echo 1 || echo 0)"

check "lightspeed Codex plugin.json bumped" \
	"$([ "$(json_version "$SANDBOX/lightspeed/.codex-plugin/plugin.json")" = "1.3.0" ] && echo 1 || echo 0)"

check "marketplace lightspeed entry bumped" \
	"$(grep -A3 '"name": "lightspeed"' "$SANDBOX/.claude-plugin/marketplace.json" | grep -q '"version": "1.3.0"' && echo 1 || echo 0)"

check "lightspeed CHANGELOG has dated new heading" \
	"$(grep -q "^## \[1.3.0\] - $TODAY\$" "$SANDBOX/lightspeed/CHANGELOG.md" && echo 1 || echo 0)"

check "lightspeed CHANGELOG has fresh empty Unreleased" \
	"$(grep -q '^## \[Unreleased\]$' "$SANDBOX/lightspeed/CHANGELOG.md" && grep -q '_Nothing yet._' "$SANDBOX/lightspeed/CHANGELOG.md" && echo 1 || echo 0)"

check "lightspeed CHANGELOG preserves prior Unreleased content" \
	"$(grep -q 'A shiny new thing.' "$SANDBOX/lightspeed/CHANGELOG.md" && echo 1 || echo 0)"

# --- isolation: the other plugin must be untouched --------------------------
check "other plugin.json untouched" \
	"$([ "$(json_version "$SANDBOX/other/.claude-plugin/plugin.json")" = "9.9.9" ] && echo 1 || echo 0)"

check "marketplace other entry untouched" \
	"$(grep -q '"version": "9.9.9"' "$SANDBOX/.claude-plugin/marketplace.json" && echo 1 || echo 0)"

check "other CHANGELOG untouched (no new dated heading)" \
	"$(! grep -q "$TODAY" "$SANDBOX/other/CHANGELOG.md" && echo 1 || echo 0)"

# --- error handling ---------------------------------------------------------
if BUMP_VERSION_ROOT="$SANDBOX" "$BUMP" 2>/dev/null; then
	check "errors when plugin arg missing" 0
else
	check "errors when plugin arg missing" 1
fi

if BUMP_VERSION_ROOT="$SANDBOX" "$BUMP" lightspeed 2>/dev/null; then
	check "errors when version arg missing" 0
else
	check "errors when version arg missing" 1
fi

if BUMP_VERSION_ROOT="$SANDBOX" "$BUMP" nosuchplugin 1.5.0 2>/dev/null; then
	check "errors on unknown plugin" 0
else
	check "errors on unknown plugin" 1
fi

if BUMP_VERSION_ROOT="$SANDBOX" "$BUMP" lightspeed not-a-version 2>/dev/null; then
	check "errors on non-semver version" 0
else
	check "errors on non-semver version" 1
fi

# lightspeed is now at 1.3.0; bumping to the same value should be refused.
if BUMP_VERSION_ROOT="$SANDBOX" "$BUMP" lightspeed 1.3.0 2>/dev/null; then
	check "errors when new version equals current" 0
else
	check "errors when new version equals current" 1
fi

# --- empty-Unreleased warning (bump 'other', whose Unreleased is a placeholder)
warn_out="$(BUMP_VERSION_ROOT="$SANDBOX" "$BUMP" other 9.10.0 2>&1 >/dev/null || true)"
check "warns when rolling an empty Unreleased section" \
	"$(printf '%s' "$warn_out" | grep -qi 'unreleased' && printf '%s' "$warn_out" | grep -qiE 'empty|nothing' && echo 1 || echo 0)"
check "still bumps despite empty Unreleased" \
	"$(json_version "$SANDBOX/other/.claude-plugin/plugin.json" | grep -qx '9.10.0' && echo 1 || echo 0)"

# --- summary ----------------------------------------------------------------
printf '\033[1m────────────────────────────\033[0m\n'
printf '\033[0;32mPassed: %d\033[0m  \033[0;31mFailed: %d\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
