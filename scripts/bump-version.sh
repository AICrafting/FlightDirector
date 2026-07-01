#!/usr/bin/env bash
# Bump one plugin's version and roll its changelog in one pass.
#
#   scripts/bump-version.sh <plugin> <new-version>
#
# The plugin's directory is resolved from its `source` in the published
# .claude-plugin/marketplace.json, so this works for any plugin in the repo.
# It moves the version fields together —
#   - <plugin-dir>/.claude-plugin/plugin.json
#   - .claude-plugin/marketplace.json  (that plugin's entry only)
# — and rolls <plugin-dir>/CHANGELOG.md: the top "## [Unreleased]" becomes
# "## [<new>] - <today>", with a fresh empty "## [Unreleased]" seeded above it.
#
# The out-of-repo dev-marketplace cache refresh stays a manual step
# (see docs/plugin-marketplace-dogfooding.md) — it's environment-local, not
# repo state.
set -euo pipefail

REPO_ROOT="${BUMP_VERSION_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
MARKETPLACE_JSON="$REPO_ROOT/.claude-plugin/marketplace.json"

die() {
	printf '\033[0;31mbump-version: %s\033[0m\n' "$1" >&2
	exit 1
}

PLUGIN="${1:-}"
NEW="${2:-}"
[ -n "$PLUGIN" ] || die "usage: bump-version.sh <plugin> <new-version> (e.g. lightspeed 0.5.0)"
[ -n "$NEW" ] || die "usage: bump-version.sh <plugin> <new-version> (e.g. lightspeed 0.5.0)"
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "not a semver X.Y.Z version: '$NEW'"
[ -f "$MARKETPLACE_JSON" ] || die "marketplace manifest not found: $MARKETPLACE_JSON"

# Resolve the plugin's source directory from its marketplace entry. The trailing
# quote in the name match keeps "light" from matching "lightspeed".
SRC="$(awk -v want="\"name\": \"$PLUGIN\"" '
	index($0, want) { found = 1 }
	found && /"source"/ {
		s = $0
		sub(/.*"source": *"/, "", s)
		sub(/".*/, "", s)
		print s
		exit
	}
' "$MARKETPLACE_JSON")"
[ -n "$SRC" ] || die "plugin '$PLUGIN' not found in $MARKETPLACE_JSON"
SRC="${SRC#./}"  # marketplace sources are written like "./lightspeed"

PLUGIN_JSON="$REPO_ROOT/$SRC/.claude-plugin/plugin.json"
CHANGELOG="$REPO_ROOT/$SRC/CHANGELOG.md"
for f in "$PLUGIN_JSON" "$CHANGELOG"; do
	[ -f "$f" ] || die "expected file not found: $f"
done

# Current version comes from the plugin's plugin.json (the source of truth).
OLD="$(grep -m1 '"version"' "$PLUGIN_JSON" | sed 's/.*"version": *"\([^"]*\)".*/\1/')"
[ -n "$OLD" ] || die "could not read current version from $PLUGIN_JSON"
[ "$OLD" != "$NEW" ] || die "$PLUGIN is already at version $NEW — nothing to bump"

# --- plugin.json: the single top-level version field ------------------------
awk -v new="$NEW" '
	!done && /"version":/ { sub(/"version": "[^"]*"/, "\"version\": \"" new "\""); done=1 }
	{ print }
' "$PLUGIN_JSON" >"$PLUGIN_JSON.tmp" && mv "$PLUGIN_JSON.tmp" "$PLUGIN_JSON"

# --- marketplace.json: only this plugin's entry -----------------------------
awk -v want="\"name\": \"$PLUGIN\"" -v new="$NEW" '
	index($0, want) { inplug = 1 }
	inplug && /"version":/ { sub(/"version": "[^"]*"/, "\"version\": \"" new "\""); inplug = 0 }
	{ print }
' "$MARKETPLACE_JSON" >"$MARKETPLACE_JSON.tmp" && mv "$MARKETPLACE_JSON.tmp" "$MARKETPLACE_JSON"

# --- CHANGELOG.md: roll [Unreleased] into a dated version -------------------
# Warn (don't block) if the Unreleased section has no real content — rolling an
# empty section produces a dated version that just says "_Nothing yet._".
unreleased_body="$(awk '
	/^## \[Unreleased\]$/ { grab=1; next }
	grab && /^## / { exit }
	grab {
		if ($0 ~ /^[[:space:]]*$/) next
		if ($0 ~ /^_Nothing yet\._[[:space:]]*$/) next
		print
	}
' "$CHANGELOG")"
[ -n "$unreleased_body" ] || printf '\033[0;33mbump-version: warning — %s'\''s [Unreleased] section is empty; %s will have nothing to show.\033[0m\n' "$PLUGIN" "$NEW" >&2

TODAY="$(date -u +%F)"
awk -v ver="$NEW" -v date="$TODAY" '
	!rolled && $0 ~ /^## \[Unreleased\]$/ {
		print "## [Unreleased]"
		print ""
		print "_Nothing yet._"
		print ""
		print "## [" ver "] - " date
		rolled = 1
		next
	}
	{ print }
	END { if (!rolled) { print "bump-version: no ## [Unreleased] heading found in " FILENAME > "/dev/stderr"; exit 1 } }
' "$CHANGELOG" >"$CHANGELOG.tmp" && mv "$CHANGELOG.tmp" "$CHANGELOG"

printf '\033[0;32mBumped %s %s → %s\033[0m (%s/.claude-plugin/plugin.json, marketplace.json, %s/CHANGELOG.md)\n' "$PLUGIN" "$OLD" "$NEW" "$SRC" "$SRC"
printf 'Reminder: refresh the dev-marketplace cache manually — see docs/plugin-marketplace-dogfooding.md\n'
