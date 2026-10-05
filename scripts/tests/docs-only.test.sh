#!/usr/bin/env bash
# Unit tests for scripts/ci/docs-only.sh (FJ-235): the classifier that lets a PR touching
# only inert docs skip the install and test steps of each CI leg. Changed-path fixtures in,
# verdict out; then the git mode against a sandbox repo with a bare "origin"; then the
# guard that keeps the allowlist honest — no test may read an allowlisted path.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLS="$REPO_ROOT/scripts/ci/docs-only.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m\n' "$1"; [ -z "${3:-}" ] || printf '      %s\n' "$3"; fail=$((fail+1)); fi; }
section() { printf '\033[1m── %s ──\033[0m\n' "$1"; }

# Keep the runner's own values (on CI this file runs inside a real Actions step) out of the
# sandbox; each case sets the ones it wants.
unset GITHUB_OUTPUT GITHUB_STEP_SUMMARY

# classify <paths…> — run the path-list mode; leaves stdout in $out, rc in $rc, and the
# GITHUB_OUTPUT / GITHUB_STEP_SUMMARY files at $T/gh-out / $T/gh-sum.
classify() {
	printf '%s\n' "$@" >"$T/paths"
	: >"$T/gh-out"; : >"$T/gh-sum"
	rc=0
	out="$(GITHUB_OUTPUT="$T/gh-out" GITHUB_STEP_SUMMARY="$T/gh-sum" bash "$CLS" --pr 7 --paths-from "$T/paths")" || rc=$?
}
cheap()  { [ "$rc" = 0 ] && [ "$(cat "$T/gh-out")" = "cheap=true" ]  && grep -q 'CHEAP path' <<<"$out"; }
full()   { [ "$rc" = 0 ] && [ "$(cat "$T/gh-out")" = "cheap=false" ] && grep -q 'FULL run' <<<"$out"; }
names()  { grep -qF "'$1'" <<<"$out"; }
full_naming() { full && names "$1"; }
cheap_saying() { cheap && grep -q "$1" <<<"$out"; }
full_saying() { full && grep -q "$1" <<<"$out"; }
ok()     { if "$@"; then echo 1; else echo 0; fi; }

section "allowlisted paths only → cheap"
classify docs/adr/README.md docs/superpowers/plans/x.md CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md
check "docs/**, CONTRIBUTING, CODE_OF_CONDUCT, SECURITY → cheap=true" "$(ok cheap)" "$out"
check "the job summary gets the same verdict line" "$(ok grep -q 'CHEAP path' "$T/gh-sum")"
check "the verdict counts the paths" "$(ok grep -q 'all 5 changed path' <<<"$out")" "$out"
printf 'docs/a.md\r\nSECURITY.md\r\n' >"$T/crlf"
rc=0; out="$(GITHUB_OUTPUT="$T/gh-out2" bash "$CLS" --pr 7 --paths-from - <"$T/crlf")" || rc=$?
check "a CRLF path list still reads as allowlisted" "$(ok grep -q 'CHEAP path' <<<"$out")" "$out"

section "anything a test reads, or anything unknown → full, naming the path"
for p in flight/skills/promoting-a-branch/SKILL.md flight/CHANGELOG.md \
	flight/references/adapter-contract.md AGENTS.md scripts/run-tests.sh scripts/ci/docs-only.sh \
	.github/workflows/tests.yml README.md flight/GUIDE.md flight/README.md CHANGELOG.md \
	notes.txt docs.md xdocs/a.md .gitattributes; do
	classify docs/a.md "$p"
	check "$p forces a full run and is named" "$(ok full_naming "$p")" "$out"
done
classify scripts/run-tests.sh docs/a.md flight/CHANGELOG.md
check "the FIRST forcing path is the one named" "$(ok names scripts/run-tests.sh)" "$out"
check "a full run writes to the job summary too" "$(ok grep -q 'FULL run' "$T/gh-sum")"

section "nothing to prove inert, or no PR → full"
: >"$T/empty"
: >"$T/gh-out"
rc=0; out="$(GITHUB_OUTPUT="$T/gh-out" bash "$CLS" --pr 7 --paths-from "$T/empty")" || rc=$?
check "an empty diff → full" "$(ok full_saying empty)" "$out"
: >"$T/gh-out"
rc=0; out="$(GITHUB_OUTPUT="$T/gh-out" bash "$CLS" --pr '' --base develop)" || rc=$?
check "no PR number (a push) → full, exit 0" "$(ok full)" "$out"
: >"$T/gh-out"
rc=0; out="$(GITHUB_OUTPUT="$T/gh-out" bash "$CLS" --pr abc --paths-from "$T/paths")" || rc=$?
check "a non-numeric PR number → full" "$(ok full)" "$out"
: >"$T/gh-out"
rc=0; out="$(GITHUB_OUTPUT="$T/gh-out" bash "$CLS" --pr 7 --bogus)" || rc=$?
check "an unknown argument → full, exit 0" "$(ok full)" "$out"
: >"$T/gh-out"
rc=0; out="$(GITHUB_OUTPUT="$T/gh-out" bash "$CLS" --pr 7 --paths-from "$T/does-not-exist")" || rc=$?
check "an unreadable path list → full" "$(ok full)" "$out"
rc=0; out="$(bash "$CLS" --pr 7 --paths-from "$T/paths")" || rc=$?
check "no GITHUB_OUTPUT set → still a verdict, exit 0" "$([ "$rc" = 0 ] && grep -q 'docs-only:' <<<"$out" && echo 1 || echo 0)" "$out"

section "git mode: HEAD against origin/<base>"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
git init -q --bare "$T/origin.git"
git init -q "$T/seed"
git -C "$T/seed" checkout -q -b develop
mkdir -p "$T/seed/docs" "$T/seed/scripts"
echo a >"$T/seed/docs/a.md"; echo s >"$T/seed/scripts/s.sh"; echo r >"$T/seed/README.md"
git -C "$T/seed" add -A; git -C "$T/seed" commit -qm seed
git -C "$T/seed" remote add origin "$T/origin.git"; git -C "$T/seed" push -q origin develop
# A shallow, single-commit clone of a PR head, as CI checks one out: origin/develop is NOT
# present locally, so the classifier has to fetch it.
mk_pr() {
	rm -rf "$T/pr"
	git -C "$T/seed" checkout -q -B "pr-$1" develop
	shift
	for f in "$@"; do mkdir -p "$(dirname "$T/seed/$f")"; echo "changed $RANDOM" >>"$T/seed/$f"; done
	git -C "$T/seed" add -A; git -C "$T/seed" commit -q --allow-empty -m pr
	git -C "$T/seed" push -q -f origin "HEAD:refs/heads/pr"
	git clone -q --depth 1 --branch pr "file://$T/origin.git" "$T/pr"
}
gitmode() {
	: >"$T/gh-out"
	rc=0; out="$(cd "$T/pr" && GITHUB_OUTPUT="$T/gh-out" bash "$CLS" --pr 7 --base "${1:-develop}")" || rc=$?
}
mk_pr docs docs/a.md docs/new/b.md
gitmode
check "docs-only PR, base not yet fetched → fetched, cheap=true" "$(ok cheap)" "$out"
mk_pr script docs/a.md scripts/s.sh
gitmode
check "a PR touching a script → full, naming it" "$(ok full_naming scripts/s.sh)" "$out"
mk_pr rename
git -C "$T/seed" mv scripts/s.sh docs/s.md; git -C "$T/seed" commit -qm mv
git -C "$T/seed" push -q -f origin "HEAD:refs/heads/pr"; rm -rf "$T/pr"
git clone -q --depth 1 --branch pr "file://$T/origin.git" "$T/pr"
gitmode
check "moving a script into docs/ still names the script (renames list both sides)" "$(ok names scripts/s.sh)" "$out"
# The base moves on (a script changes on develop) after a docs-only PR forked from it.
mk_pr moved docs/c.md
git -C "$T/seed" checkout -q develop; echo more >>"$T/seed/scripts/s.sh"
git -C "$T/seed" commit -qam "develop moves on"; git -C "$T/seed" push -q origin develop
gitmode
check "base moved on, shallow checkout → unshallowed, judged since the fork: cheap" \
	"$(ok cheap_saying 'since the fork')" "$out"
# Same, but origin cannot be reached for the unshallow: only the base tip is local, so the
# fallback compares trees, sees develop's script change, and errs to a full run.
rm -rf "$T/pr"; git clone -q --depth 1 --branch pr "file://$T/origin.git" "$T/pr"
git -C "$T/pr" fetch -q --depth 1 origin "+refs/heads/develop:refs/remotes/origin/develop"
git -C "$T/pr" remote set-url origin "file://$T/nowhere.git"
gitmode
check "no merge base reachable → tree diff against the base tip, which errs to full" "$(ok full_naming scripts/s.sh)" "$out"
gitmode no-such-branch
check "an unfetchable base ref → full, exit 0" "$(ok full_saying 'could not be resolved')" "$out"
gitmode 'bad..name'
check "an invalid base name → full" "$(ok full)" "$out"
mkdir -p "$T/notgit"
: >"$T/gh-out"
rc=0; out="$(cd "$T/notgit" && GIT_CEILING_DIRECTORIES="$T" GITHUB_OUTPUT="$T/gh-out" bash "$CLS" --pr 7 --base develop)" || rc=$?
check "a classifier error (not a git checkout) → full, exit 0" "$(ok full)" "$out"
rm -rf "$T/pr"; git clone -q "file://$T/origin.git" "$T/pr" 2>/dev/null; git -C "$T/pr" checkout -q develop
gitmode
check "an empty diff (HEAD is the base) → full" "$(ok full_saying empty)" "$out"

# ── the allowlist versus what the tests read ─────────────────────────────────────────
# A test that reads a file makes that file part of what CI measures, so it can never be
# on the allowlist. reads_allowlisted <test file> prints each reference that hits an
# allowlisted pattern: any `*.md` token (and every suffix of it after a `/`, so
# "$REPO_ROOT/CONTRIBUTING.md" and a bare "CONTRIBUTING.md" in an array both count), and
# any path written after a repo-root variable (so a directory read such as
# "$REPO_ROOT/docs" counts). Comments are scanned too: over-matching only fails safe.
ALLOW="$(bash "$CLS" --print-allowlist)"
hits_allowlist() {   # <path> → 0 when <path>, or the directory it names, is allowlisted
	local p="$1" pat
	while IFS= read -r pat; do
		[ -n "$pat" ] || continue
		# shellcheck disable=SC2254 # the patterns are meant to glob
		case "$p" in $pat|$pat/*) return 0 ;; esac
		# a directory read: "docs" against "docs/*"
		case "$pat" in */\*) [ "$p" = "${pat%/\*}" ] && return 0 ;; esac
	done <<EOF
$ALLOW
EOF
	return 1
}
reads_allowlisted() {
	local tok s
	{
		tr -d '\r' <"$1" | grep -oE '[A-Za-z0-9_./*-]*\.md' || true
		tr -d '\r' <"$1" | grep -oE 'ROOT\}?/[A-Za-z0-9_./-]+' | sed -E 's#^ROOT\}?/##; s#/+$##' || true
	} | sort -u | while IFS= read -r tok; do
		s="$tok"
		while :; do
			if hits_allowlist "$s"; then printf '%s: %s\n' "$(basename "$1")" "$tok"; break; fi
			case "$s" in */*) s="${s#*/}" ;; *) break ;; esac
		done
	done
}

section "the allowlist is not read by any test"
for f in "$REPO_ROOT"/scripts/tests/*.test.sh; do
	# This file names allowlisted paths as fixtures; it reads none of them.
	[ "$(basename "$f")" = docs-only.test.sh ] && continue
	reads_allowlisted "$f"
done >"$T/violations"
violations="$(cat "$T/violations")"
check "no scripts/tests/*.test.sh references an allowlisted path" "$([ -z "$violations" ] && echo 1 || echo 0)" "$violations"
check "the allowlist is non-empty and carries no flight/ path" \
	"$([ -n "$ALLOW" ] && ! grep -q '^flight/' <<<"$ALLOW" && echo 1 || echo 0)" "$ALLOW"

section "the guard catches a test that starts reading an allowlisted path"
# shellcheck disable=SC2016 # literal test-file text, expanded by nothing
printf '#!/usr/bin/env bash\ngrep -q x "$REPO_ROOT/CONTRIBUTING.md"\n' >"$T/a.test.sh"
check "a \$REPO_ROOT/<allowlisted .md> read is flagged" "$(ok grep -q CONTRIBUTING <<<"$(reads_allowlisted "$T/a.test.sh")")"
printf 'DOCS=(README.md SECURITY.md)\n' >"$T/b.test.sh"
check "a bare allowlisted name in a list is flagged" "$(ok grep -q SECURITY <<<"$(reads_allowlisted "$T/b.test.sh")")"
# shellcheck disable=SC2016 # literal test-file text, expanded by nothing
printf 'find "$REPO_ROOT/docs" -name x\n' >"$T/c.test.sh"
check "a read of an allowlisted directory is flagged" "$(ok grep -q docs <<<"$(reads_allowlisted "$T/c.test.sh")")"
# shellcheck disable=SC2016 # literal test-file text, expanded by nothing
printf 'cat "${REPO_ROOT}/docs/adr/README.md"\n' >"$T/d.test.sh"
check "a file under an allowlisted directory is flagged" "$(ok grep -q 'docs/adr' <<<"$(reads_allowlisted "$T/d.test.sh")")"
# shellcheck disable=SC2016 # literal test-file text, expanded by nothing
printf 'grep -q x "$REPO_ROOT/flight/GUIDE.md" "$T/CHANGELOG.md"\n' >"$T/e.test.sh"
check "reads of non-allowlisted paths are not flagged" "$([ -z "$(reads_allowlisted "$T/e.test.sh")" ] && echo 1 || echo 0)"

# Summary: plain when nothing failed, red when something did (#123).
[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
