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
[ -n "$PLUGIN" ] || die "usage: bump-version.sh <plugin> <new-version> (e.g. flight 0.5.0)"
[ -n "$NEW" ] || die "usage: bump-version.sh <plugin> <new-version> (e.g. flight 0.5.0)"
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "not a semver X.Y.Z version: '$NEW'"
[ -f "$MARKETPLACE_JSON" ] || die "marketplace manifest not found: $MARKETPLACE_JSON"

# Resolve the plugin's source directory from its marketplace entry. The trailing
# quote in the name match keeps a prefix like "fli" from matching "flight".
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
SRC="${SRC#./}"  # marketplace sources are written like "./flight"

PLUGIN_JSON="$REPO_ROOT/$SRC/.claude-plugin/plugin.json"
CODEX_PLUGIN_JSON="$REPO_ROOT/$SRC/.codex-plugin/plugin.json"
CHANGELOG="$REPO_ROOT/$SRC/CHANGELOG.md"
for f in "$PLUGIN_JSON" "$CHANGELOG"; do
	[ -f "$f" ] || die "expected file not found: $f"
done
[ -f "$CODEX_PLUGIN_JSON" ] || CODEX_PLUGIN_JSON=""

# Current version comes from the plugin's plugin.json (the source of truth).
OLD="$(grep -m1 '"version"' "$PLUGIN_JSON" | sed 's/.*"version": *"\([^"]*\)".*/\1/')"
[ -n "$OLD" ] || die "could not read current version from $PLUGIN_JSON"
[ "$OLD" != "$NEW" ] || die "$PLUGIN is already at version $NEW — nothing to bump"
# Check the changelog can be rolled BEFORE touching any manifest, so a missing heading
# never leaves the versions bumped and the changelog not. (\r-tolerant: see below.)
awk '{ sub(/\r$/, "") } /^## \[Unreleased\]$/ { found = 1 } END { exit !found }' "$CHANGELOG" \
	|| die "no ## [Unreleased] heading found in $CHANGELOG — nothing was changed"

# --- plugin.json: the single top-level version field ------------------------
awk -v new="$NEW" '
	!done && /"version":/ { sub(/"version": "[^"]*"/, "\"version\": \"" new "\""); done=1 }
	{ print }
' "$PLUGIN_JSON" >"$PLUGIN_JSON.tmp" && mv "$PLUGIN_JSON.tmp" "$PLUGIN_JSON"

# Keep the optional Codex manifest in lockstep with the Claude source-of-truth.
if [ -n "$CODEX_PLUGIN_JSON" ]; then
	awk -v new="$NEW" '
		!done && /"version":/ { sub(/"version": "[^"]*"/, "\"version\": \"" new "\""); done=1 }
		{ print }
	' "$CODEX_PLUGIN_JSON" >"$CODEX_PLUGIN_JSON.tmp" && mv "$CODEX_PLUGIN_JSON.tmp" "$CODEX_PLUGIN_JSON"
fi

# --- marketplace.json: only this plugin's entry -----------------------------
awk -v want="\"name\": \"$PLUGIN\"" -v new="$NEW" '
	index($0, want) { inplug = 1 }
	inplug && /"version":/ { sub(/"version": "[^"]*"/, "\"version\": \"" new "\""); inplug = 0 }
	{ print }
' "$MARKETPLACE_JSON" >"$MARKETPLACE_JSON.tmp" && mv "$MARKETPLACE_JSON.tmp" "$MARKETPLACE_JSON"

# --- CHANGELOG.md: roll [Unreleased] into a dated version -------------------
# Warn (don't block) if the Unreleased section has no real content — rolling an
# empty section produces a dated version that just says "_Nothing yet._".
# Markdown keeps native line endings (.gitattributes), so on a Windows checkout every line
# of the changelog ends in \r. Match on the line without it, and write any new lines with
# the file's own ending, or the heading is never found and the roll silently does nothing.
unreleased_body="$(awk '
	{ line = $0; sub(/\r$/, "", line) }
	line ~ /^## \[Unreleased\]$/ { grab=1; next }
	grab && line ~ /^## / { exit }
	grab {
		if (line ~ /^[[:space:]]*$/) next
		if (line ~ /^_Nothing yet\._[[:space:]]*$/) next
		print line
	}
' "$CHANGELOG")"
[ -n "$unreleased_body" ] || printf '\033[0;33mbump-version: warning — %s'\''s [Unreleased] section is empty; %s will have nothing to show.\033[0m\n' "$PLUGIN" "$NEW" >&2

TODAY="$(date -u +%F)"
awk -v ver="$NEW" -v date="$TODAY" '
	{ line = $0; eol = (sub(/\r$/, "", line) ? "\r" : "") }
	!rolled && line ~ /^## \[Unreleased\]$/ {
		print "## [Unreleased]" eol
		print eol
		print "_Nothing yet._" eol
		print eol
		print "## [" ver "] - " date eol
		rolled = 1
		next
	}
	{ print }
	END { if (!rolled) { print "bump-version: no ## [Unreleased] heading found in " FILENAME > "/dev/stderr"; exit 1 } }
' "$CHANGELOG" >"$CHANGELOG.tmp" || { rm -f "$CHANGELOG.tmp"; die "could not roll $CHANGELOG (manifests are already at $NEW)"; }
mv "$CHANGELOG.tmp" "$CHANGELOG"

printf '\033[0;32mBumped %s %s → %s\033[0m (%s/.claude-plugin/plugin.json, marketplace.json, %s/CHANGELOG.md)\n' "$PLUGIN" "$OLD" "$NEW" "$SRC" "$SRC"
printf 'Reminder: refresh the dev-marketplace cache manually — see docs/plugin-marketplace-dogfooding.md\n'
