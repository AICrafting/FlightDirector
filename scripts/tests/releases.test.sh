#!/usr/bin/env bash
# Unit tests for this repo's release tagging tooling (#36):
# scripts/release-notes.sh and scripts/tag-release.sh. Uses a sandbox repo with
# a bare "origin" and a fake curl on PATH — no network, no real signing.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NOTES="$REPO_ROOT/scripts/release-notes.sh"
TAGREL="$REPO_ROOT/scripts/tag-release.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m\n' "$1"; fail=$((fail+1)); fi; }

# ---------------------------------------------------------------------------
# release-notes.sh
# ---------------------------------------------------------------------------
cat >"$T/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

_Nothing yet._

## [0.12.0] - 2026-09-08

### Added

- **Thing one** (#1).
- Thing two.

## [0.11.0] - 2026-09-06

### Changed

- Older stuff.

## [0.1.0] - 2026-01-01

- ancient
EOF
out="$("$NOTES" --changelog "$T/CHANGELOG.md" --version 0.12.0)"
check "extracts exactly the version's section (stops at the next heading)" \
	"$(printf '%s' "$out" | grep -q 'Thing one' && printf '%s' "$out" | grep -q 'Thing two' && ! printf '%s' "$out" | grep -q 'Older stuff' && echo 1 || echo 0)"
check "excludes the heading by default and trims blank edges" \
	"$([ "$(printf '%s' "$out" | head -1)" = "### Added" ] && [ "$(printf '%s' "$out" | tail -1)" = "- Thing two." ] && echo 1 || echo 0)"
out2="$("$NOTES" --changelog "$T/CHANGELOG.md" --version 0.12.0 --title)"
check "--title keeps the heading as the first line" "$([ "$(printf '%s' "$out2" | head -1)" = "## [0.12.0] - 2026-09-08" ] && echo 1 || echo 0)"
if "$NOTES" --changelog "$T/CHANGELOG.md" --version 9.9.9 >/dev/null 2>"$T/err"; then rc=0; else rc=$?; fi
check "missing version → exit 1 with a message" "$([ "$rc" = 1 ] && grep -q '9.9.9' "$T/err" && echo 1 || echo 0)"
out3="$("$NOTES" --changelog "$T/CHANGELOG.md" --version 0.1.0)"
check "version match is literal (0.1.0 does not pick up 0.11.0)" "$([ "$out3" = "- ancient" ] && echo 1 || echo 0)"
out4="$("$NOTES" --changelog - --version 0.11.0 <"$T/CHANGELOG.md")"
check "reads the changelog from stdin with '-'" "$([ "$(printf '%s' "$out4" | tail -1)" = "- Older stuff." ] && echo 1 || echo 0)"
real="$("$NOTES" --changelog "$REPO_ROOT/flight/CHANGELOG.md" --version 0.11.0 | head -1)"
check "works on the repo's real CHANGELOG (0.11.0 section found)" "$([ -n "$real" ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# sandbox repo: marketplace + plugin at 0.12.0 on main, bare origin, fake curl
# ---------------------------------------------------------------------------
R="$T/repo"; B="$T/origin.git"
git init -q --bare -b main "$B"
git init -q -b main "$R"
git -C "$R" config user.email t@t; git -C "$R" config user.name t; git -C "$R" config commit.gpgsign false
mkdir -p "$R/.claude-plugin" "$R/flight/.claude-plugin" "$R/.flightdirector"
cat >"$R/.claude-plugin/marketplace.json" <<'EOF'
{"name":"flightdirector","plugins":[{"name":"flight","source":"./flight","version":"0.12.0"}]}
EOF
echo '{"name":"flight","version":"0.12.0"}' >"$R/flight/.claude-plugin/plugin.json"
cp "$T/CHANGELOG.md" "$R/flight/CHANGELOG.md"
echo '{"code":{"backend":"forgejo","owner":"o","repo":"r","api":"https://forge.invalid/api/v1","stages":[{"name":"main"}]}}' >"$R/.flightdirector/config.json"
echo '{"code":{"token":"sekrit"}}' >"$R/.flightdirector/secrets.json"
printf '.flightdirector/secrets.json\n' >"$R/.gitignore"
git -C "$R" add -A; git -C "$R" commit -q -m "release: 0.12.0"
git -C "$R" remote add origin "$B"; git -C "$R" push -q origin main
SHA="$(git -C "$R" rev-parse HEAD)"

mkdir -p "$T/bin"
cat >"$T/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""; method=GET; url=""; data=""; auth=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-w) shift 2 ;;
		-X) method="$2"; shift 2 ;;
		-H) case "$2" in Authorization:*) auth="$2" ;; esac; shift 2 ;;
		--data-binary) data="$2"; shift 2 ;;
		-sS) shift ;;
		*) url="$1"; shift ;;
	esac
done
printf '%s %s %s\n' "$method" "$url" "$auth" >>"${CURL_LOG:?}"
printf '%s\n' "$data" >"${CURL_BODY:?}"
printf '%s' '{"id":7,"html_url":"https://forge.invalid/o/r/releases/tag/flight-0.12.0"}' >"$out"
printf '%s' "${FAKE_CODE:-201}"
SH
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH" CURL_LOG="$T/curl.log" CURL_BODY="$T/body.json" TAG_RELEASE_ROOT="$R"
run() { env -u FLIGHT_TOKEN -u LS_TOKEN "$TAGREL" "$@"; }

# --- dry run touches nothing ---
: >"$CURL_LOG"
out="$(run flight --dry-run)"
check "dry-run resolves version and tag from plugin.json at origin/main" "$(grep -q 'flight 0.12.0 at origin/main' <<<"$out" && grep -q 'tag flight-0.12.0' <<<"$out" && echo 1 || echo 0)"
check "dry-run prints the notes" "$(grep -q 'Thing one' <<<"$out" && echo 1 || echo 0)"
check "dry-run creates no tag and no Release" "$(! git -C "$R" rev-parse -q --verify refs/tags/flight-0.12.0 >/dev/null && [ ! -s "$CURL_LOG" ] && echo 1 || echo 0)"

# --- the real thing ---
: >"$CURL_LOG"; rm -f "$CURL_BODY"
out="$(run flight)"
check "creates an annotated tag <plugin>-<version> on the origin/main commit" \
	"$([ "$(git -C "$R" cat-file -t flight-0.12.0)" = tag ] && [ "$(git -C "$R" rev-parse 'flight-0.12.0^{commit}')" = "$SHA" ] && echo 1 || echo 0)"
check "tag message is '<plugin> <version>' + the CHANGELOG section" \
	"$(git -C "$R" tag -l --format='%(contents)' flight-0.12.0 | head -1 | grep -q '^flight 0.12.0$' && git -C "$R" tag -l --format='%(contents)' flight-0.12.0 | grep -q 'Thing one' && echo 1 || echo 0)"
check "unsigned annotated when commit.gpgsign is off" "$(grep -q 'unsigned annotated' <<<"$out" && echo 1 || echo 0)"
check "tag pushed to origin" "$(git -C "$B" rev-parse -q --verify refs/tags/flight-0.12.0 >/dev/null && echo 1 || echo 0)"
check "Release POSTed to <api>/repos/<owner>/<repo>/releases with the secrets token" \
	"$(grep -q 'POST https://forge.invalid/api/v1/repos/o/r/releases Authorization: token sekrit' "$CURL_LOG" && echo 1 || echo 0)"
check "Release payload: tag, name, target sha, notes, not draft/prerelease" \
	"$(jq -e --arg s "$SHA" '.tag_name=="flight-0.12.0" and .name=="flight-0.12.0" and .target_commitish==$s and (.body|contains("Thing one")) and .draft==false and .prerelease==false' "$CURL_BODY" >/dev/null && echo 1 || echo 0)"
check "prints the Release URL" "$(grep -q 'releases/tag/flight-0.12.0' <<<"$out" && echo 1 || echo 0)"

# --- immutability ---
: >"$CURL_LOG"
if run flight >/dev/null 2>"$T/again.err"; then rc=0; else rc=$?; fi
check "re-running for an existing tag refuses (exit 1) and names the tag" "$([ "$rc" = 1 ] && grep -q 'flight-0.12.0 already exists' "$T/again.err" && echo 1 || echo 0)"
check "…and makes no API call" "$([ ! -s "$CURL_LOG" ] && echo 1 || echo 0)"
git -C "$R" tag -d flight-0.12.0 >/dev/null
if run flight >/dev/null 2>"$T/remote.err"; then rc=0; else rc=$?; fi
check "a tag that exists only on the remote is also refused" "$([ "$rc" = 1 ] && grep -q 'already exists on origin' "$T/remote.err" && echo 1 || echo 0)"
git -C "$R" push -q --delete origin flight-0.12.0

# --- guards ---
env FLIGHT_TOKEN=envtok "$TAGREL" flight --no-release >/dev/null
check "--no-release tags and pushes but skips the Release" "$(git -C "$B" rev-parse -q --verify refs/tags/flight-0.12.0 >/dev/null && [ ! -s "$CURL_LOG" ] && echo 1 || echo 0)"
git -C "$R" tag -d flight-0.12.0 >/dev/null; git -C "$R" push -q --delete origin flight-0.12.0
: >"$CURL_LOG"
env FLIGHT_TOKEN=envtok "$TAGREL" flight >/dev/null
check "FLIGHT_TOKEN overrides the secrets file token" "$(grep -q 'Authorization: token envtok' "$CURL_LOG" && echo 1 || echo 0)"
git -C "$R" tag -d flight-0.12.0 >/dev/null; git -C "$R" push -q --delete origin flight-0.12.0
# missing changelog section → refuse before tagging
sed -i 's/## \[0.12.0\]/## [0.12.9]/' "$R/flight/CHANGELOG.md"; git -C "$R" commit -qam "break changelog"; git -C "$R" push -q origin main
if run flight >/dev/null 2>"$T/nolog.err"; then rc=0; else rc=$?; fi
check "no CHANGELOG section for the version → refuses before tagging" "$([ "$rc" = 1 ] && grep -q '0.12.0' "$T/nolog.err" && ! git -C "$R" rev-parse -q --verify refs/tags/flight-0.12.0 >/dev/null && echo 1 || echo 0)"
if run nosuch --dry-run >/dev/null 2>"$T/plug.err"; then rc=0; else rc=$?; fi
check "unknown plugin errors" "$([ "$rc" = 1 ] && grep -q "nosuch" "$T/plug.err" && echo 1 || echo 0)"
if run flight --bogus >/dev/null 2>&1; then rc=0; else rc=$?; fi
check "unknown option errors" "$([ "$rc" != 0 ] && echo 1 || echo 0)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
