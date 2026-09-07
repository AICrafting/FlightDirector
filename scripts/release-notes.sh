#!/usr/bin/env bash
# Extract one version's section from a Keep-a-Changelog file — the text that
# becomes a release tag's annotation and the Forgejo Release body.
#
#   scripts/release-notes.sh --changelog <path> --version <X.Y.Z> [--title]
#
# Prints the body under `## [X.Y.Z]` (or `## [X.Y.Z] - <date>`) up to the next
# `## ` heading, with leading/trailing blank lines trimmed. With --title the
# first line is the heading itself. Exits 1 with a message on stderr when the
# section is missing or empty — never tag a release with no notes.
set -euo pipefail

die() { printf 'release-notes: %s\n' "$1" >&2; exit 1; }

changelog=""; version=""; with_title=0
while [ $# -gt 0 ]; do
	case "$1" in
		--changelog) [ $# -ge 2 ] || die "missing value for $1"; changelog="$2"; shift 2 ;;
		--version)   [ $# -ge 2 ] || die "missing value for $1"; version="$2"; shift 2 ;;
		--title)     with_title=1; shift ;;
		*) die "unknown argument: $1" ;;
	esac
done
[ -n "$changelog" ] || die "--changelog is required"
[ -n "$version" ]   || die "--version is required"
[ -f "$changelog" ] || [ "$changelog" = "-" ] || die "changelog not found: $changelog"
[ "$changelog" = "-" ] && changelog=/dev/stdin

section="$(awk -v ver="$version" '
	BEGIN { esc = ver; gsub(/[.]/, "[.]", esc); pat = "^## \\[" esc "\\]" }
	$0 ~ pat { grab = 1; if (title) print; next }
	grab && /^## / { exit }
	grab { print }
' title="$with_title" "$changelog")"

# Trim leading and trailing blank lines.
section="$(printf '%s\n' "$section" | awk 'NF { blank = 0 } { if (!seen && !NF) next; seen = 1; if (!NF) { held++ ; next } while (held) { print ""; held-- } print }')"

[ -n "$section" ] || die "no non-empty section for version $version in $changelog"
printf '%s\n' "$section"
