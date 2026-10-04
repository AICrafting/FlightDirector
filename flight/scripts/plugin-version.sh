#!/usr/bin/env bash
# Reports which flight plugin the harness actually loaded (FJ-257) — the engine behind the
# `/flight:version` command. `flight --version` answers a different question: it reports the
# dispatcher on PATH, which in a dev checkout is the live tree, not the copy the skills and hooks
# were loaded from. After a version bump (before the cache is refreshed), or with both a published
# and a dev install present, the two disagree; this prints both and says so.
#
#   plugin-version.sh [--root <plugin root>] [--json]
#
# The plugin root defaults to this script's parent directory, i.e. ${CLAUDE_PLUGIN_ROOT} when
# the command runs it from there. The manifest is the root's .claude-plugin/plugin.json (the
# .codex-plugin one when only that exists). The install (`<plugin>@<marketplace>`) is derived
# from the root's path only when it has a known cache/marketplace layout; otherwise it is
# `unknown` — never guessed.
set -euo pipefail

die() { echo "plugin-version: $*" >&2; exit 1; }

root=""
json=0
while [ $# -gt 0 ]; do
	case "$1" in
		--root) [ $# -ge 2 ] || die "--root needs a directory"; root="$2"; shift 2 ;;
		--json) json=1; shift ;;
		-h | --help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) die "usage: plugin-version.sh [--root <plugin root>] [--json]" ;;
	esac
done

command -v jq >/dev/null 2>&1 || die "jq is required but not installed"

if [ -z "$root" ]; then
	root="$(cd "$(dirname "$0")/.." && pwd)"
else
	[ -d "$root" ] || die "no such plugin root: $root"
	root="$(cd "$root" && pwd)"
fi

manifest="$root/.claude-plugin/plugin.json"
[ -f "$manifest" ] || manifest="$root/.codex-plugin/plugin.json"
[ -f "$manifest" ] || die "no plugin manifest under $root (.claude-plugin/ or .codex-plugin/plugin.json)"
name="$(jq -r '.name // empty' "$manifest")"
version="$(jq -r '.version // empty' "$manifest")"
[ -n "$name" ] || name="unknown"
[ -n "$version" ] || version="unknown"

# Install, from the two layouts a harness installs plugins into:
#   …/plugins/cache/<marketplace>/<plugin>/<version>   (the versioned plugin cache)
#   …/plugins/marketplaces/<marketplace>/<plugin>      (a marketplace's own checkout)
# Anything else (a dev tree, a --plugin-dir load) is `unknown`.
install="unknown"
norm="${root//\\//}"
if [[ "$norm" =~ /plugins/cache/([^/]+)/([^/]+)/[^/]+$ ]]; then
	install="${BASH_REMATCH[2]}@${BASH_REMATCH[1]}"
elif [[ "$norm" =~ /plugins/marketplaces/([^/]+)/([^/]+)$ ]]; then
	install="${BASH_REMATCH[2]}@${BASH_REMATCH[1]}"
fi

# The dispatcher on PATH. An older one without --version reads as `unknown`.
disp_path="$(command -v flight 2>/dev/null || true)"
disp_version=""
if [ -n "$disp_path" ]; then
	disp_version="$(flight --version 2>/dev/null | awk 'NR==1 {print $NF}' || true)"
	[ -n "$disp_version" ] || disp_version="unknown"
fi

note=""
if [ -z "$disp_path" ]; then
	note="no \`flight\` dispatcher on PATH"
elif [ "$disp_version" != "$version" ]; then
	note="the \`flight\` on PATH ($disp_version) differs from the loaded plugin ($version) — the skills and hooks run from the plugin root above, the CLI from $disp_path"
fi

if [ "$json" = 1 ]; then
	jq -n --arg n "$name" --arg v "$version" --arg r "$root" --arg i "$install" \
		--arg dp "$disp_path" --arg dv "$disp_version" --arg note "$note" '{
			plugin: $n, version: $v, root: $r, install: $i,
			dispatcher: (if $dp == "" then null else {path: $dp, version: $dv} end),
			matches: ($dp != "" and $dv == $v),
			note: (if $note == "" then null else $note end)
		}'
	exit 0
fi

printf '%s %s\n' "$name" "$version"
printf '  install:     %s\n' "$install"
printf '  plugin root: %s\n' "$root"
if [ -n "$disp_path" ]; then
	printf '  dispatcher:  flight %s (%s)\n' "$disp_version" "$disp_path"
else
	printf '  dispatcher:  not on PATH\n'
fi
[ -z "$note" ] || printf 'note: %s\n' "$note"
