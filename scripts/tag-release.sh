#!/usr/bin/env bash
# Tag a plugin release in THIS repo and create the matching Forgejo Release.
#
#   scripts/tag-release.sh <plugin> [--ref <rev>] [--push-to <remote>]... [--no-release] [--dry-run]
#
# Run after a version has reached `main` (the terminal stage). It:
#   1. reads the plugin's version from <plugin>/.claude-plugin/plugin.json at --ref
#      (default: origin/main, after a fetch) — the tag is `<plugin>-<version>`;
#   2. refuses if that tag already exists locally or on the remote (tags are
#      immutable anchors — cut the next version instead);
#   3. takes the version's section of <plugin>/CHANGELOG.md at --ref as the notes
#      (via scripts/release-notes.sh) and refuses if it is missing or empty;
#   4. creates an annotated tag on that commit — signed (`-s`) when commit.gpgsign
#      is on, which the pre-push hook already requires for commits — and pushes it
#      to each --push-to remote (default: origin);
#   5. creates a Forgejo Release for the tag with the same notes, using the
#      coordinates in .flightdirector/config.json and the token from
#      .flightdirector/secrets.json (env FLIGHT_TOKEN / LS_TOKEN override).
#      Skip with --no-release.
#
# --dry-run prints every step and touches nothing. The plugin's directory is
# resolved from .claude-plugin/marketplace.json, like bump-version.sh, so this
# works for any plugin in the repo.
#
# This is repo tooling for Flight Director's own releases; it is not shipped in
# the plugin. (A generic "tag releases" workflow for flight users is a different
# plugin's job — see issue #36.)
set -euo pipefail

REPO_ROOT="${TAG_RELEASE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
NOTES_SH="$(cd "$(dirname "$0")" && pwd)/release-notes.sh"
MARKETPLACE_JSON="$REPO_ROOT/.claude-plugin/marketplace.json"
CFG="$REPO_ROOT/.flightdirector/config.json"
SEC="$REPO_ROOT/.flightdirector/secrets.json"

die() { printf '\033[0;31mtag-release: %s\033[0m\n' "$1" >&2; exit 1; }
say() { printf '\033[0;32mtag-release:\033[0m %s\n' "$1"; }
command -v jq >/dev/null 2>&1 || die "jq is required"

PLUGIN=""; REF="origin/main"; DRY=0; RELEASE=1; PUSH_TO=()
while [ $# -gt 0 ]; do
	case "$1" in
		--ref)        [ $# -ge 2 ] || die "missing value for $1"; REF="$2"; shift 2 ;;
		--push-to)    [ $# -ge 2 ] || die "missing value for $1"; PUSH_TO+=("$2"); shift 2 ;;
		--no-release) RELEASE=0; shift ;;
		--dry-run)    DRY=1; shift ;;
		-*)           die "unknown option: $1" ;;
		*)            [ -z "$PLUGIN" ] || die "unexpected argument: $1"; PLUGIN="$1"; shift ;;
	esac
done
[ -n "$PLUGIN" ] || die "usage: tag-release.sh <plugin> [--ref <rev>] [--push-to <remote>]... [--no-release] [--dry-run]"
[ ${#PUSH_TO[@]} -gt 0 ] || PUSH_TO=(origin)
[ -f "$MARKETPLACE_JSON" ] || die "marketplace manifest not found: $MARKETPLACE_JSON"

# --- resolve the plugin directory from the marketplace entry ----------------
SRC="$(jq -r --arg p "$PLUGIN" '.plugins[]? | select(.name == $p) | .source // empty' "$MARKETPLACE_JSON")"
[ -n "$SRC" ] || die "plugin '$PLUGIN' not found in $MARKETPLACE_JSON"
SRC="${SRC#./}"

# --- fetch and read the version at REF ----------------------------------------
case "$REF" in
	origin/*) git -C "$REPO_ROOT" fetch -q origin "${REF#origin/}" 2>/dev/null || die "cannot fetch ${REF#origin/} from origin" ;;
esac
SHA="$(git -C "$REPO_ROOT" rev-parse --verify -q "$REF^{commit}")" || die "unknown ref: $REF"
VERSION="$(git -C "$REPO_ROOT" show "$SHA:$SRC/.claude-plugin/plugin.json" 2>/dev/null | jq -r '.version // empty')"
[ -n "$VERSION" ] || die "no version in $SRC/.claude-plugin/plugin.json at $REF"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "not a semver X.Y.Z version at $REF: '$VERSION'"
TAG="$PLUGIN-$VERSION"
say "$PLUGIN $VERSION at $REF (${SHA:0:7}) → tag $TAG"

# --- refuse to move an existing tag ------------------------------------------
if git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
	die "tag $TAG already exists locally ($(git -C "$REPO_ROOT" rev-parse --short "$TAG^{commit}")) — tags are immutable; bump and ship the next version instead"
fi
for remote in "${PUSH_TO[@]}"; do
	if git -C "$REPO_ROOT" ls-remote --exit-code --tags "$remote" "refs/tags/$TAG" >/dev/null 2>&1; then
		die "tag $TAG already exists on $remote — fetch it (git fetch --tags $remote) rather than re-creating it"
	fi
done

# --- release notes from the CHANGELOG at REF ----------------------------------
NOTES="$(git -C "$REPO_ROOT" show "$SHA:$SRC/CHANGELOG.md" 2>/dev/null | "$NOTES_SH" --changelog - --version "$VERSION")" \
	|| die "no non-empty '## [$VERSION]' section in $SRC/CHANGELOG.md at $REF — fold the changelog before tagging"
NOTES_FILE="$(mktemp)"; trap 'rm -f "$NOTES_FILE"' EXIT
{ printf '%s %s\n\n' "$PLUGIN" "$VERSION"; printf '%s\n' "$NOTES"; } >"$NOTES_FILE"

# --- sign when commits are signed -------------------------------------------
SIGN=-a
[ "$(git -C "$REPO_ROOT" config --get commit.gpgsign 2>/dev/null || echo false)" = true ] && SIGN=-s

if [ "$DRY" = 1 ]; then
	say "[dry-run] would: git tag $SIGN $TAG -F <notes> ${SHA:0:7}"
	for remote in "${PUSH_TO[@]}"; do say "[dry-run] would: git push $remote refs/tags/$TAG"; done
	[ "$RELEASE" = 1 ] && say "[dry-run] would: create Forgejo Release '$TAG' via $(jq -r '.code.api // "?"' "$CFG" 2>/dev/null)/repos/…/releases"
	printf '\n--- notes ---\n%s\n' "$(cat "$NOTES_FILE")"
	exit 0
fi

# --- tag + push ---------------------------------------------------------------
git -C "$REPO_ROOT" tag "$SIGN" "$TAG" -F "$NOTES_FILE" "$SHA"
say "created tag $TAG on ${SHA:0:7} ($([ "$SIGN" = -s ] && echo signed || echo unsigned) annotated)"
for remote in "${PUSH_TO[@]}"; do
	git -C "$REPO_ROOT" push "$remote" "refs/tags/$TAG"
	say "pushed $TAG to $remote"
done

# --- Forgejo Release -----------------------------------------------------------
[ "$RELEASE" = 1 ] || { say "skipping backend Release (--no-release)"; exit 0; }
[ -f "$CFG" ] || die "no $CFG — cannot create the Forgejo Release (tag is pushed; use --no-release to silence)"
API="$(jq -r '.code.api // empty' "$CFG")"; OWNER="$(jq -r '.code.owner // empty' "$CFG")"; REPO="$(jq -r '.code.repo // empty' "$CFG")"
[ -n "$API" ] && [ -n "$OWNER" ] && [ -n "$REPO" ] || die "code.api/owner/repo missing in $CFG"
TOKEN="${FLIGHT_TOKEN:-${LS_TOKEN:-}}"
[ -n "$TOKEN" ] || { [ -f "$SEC" ] && TOKEN="$(jq -r '.code.token // empty' "$SEC")"; }
[ -n "$TOKEN" ] || die "no token (FLIGHT_TOKEN / LS_TOKEN / $SEC code.token) — tag is pushed; create the Release by hand or rerun with a token"
PAYLOAD="$(jq -n --arg t "$TAG" --arg n "$TAG" --arg c "$SHA" --rawfile body "$NOTES_FILE" \
	'{tag_name:$t, name:$n, target_commitish:$c, body:$body, draft:false, prerelease:false}')"
RESP="$(mktemp)"; trap 'rm -f "$NOTES_FILE" "$RESP"' EXIT
CODE="$(curl -sS -o "$RESP" -w '%{http_code}' -X POST -H "Authorization: token $TOKEN" -H "Content-Type: application/json" \
	--data-binary "$PAYLOAD" "${API%/}/repos/$OWNER/$REPO/releases")" || die "curl failed creating the Release (tag is pushed)"
[ "$CODE" -lt 400 ] || die "Release creation → HTTP $CODE: $(jq -r '.message // empty' "$RESP" 2>/dev/null) (tag is pushed)"
say "Forgejo Release: $(jq -r '.html_url // "created"' "$RESP")"
