#!/usr/bin/env bash
# Unit tests for scripts/push-mirror.sh (#106): sandbox repo with two bare
# remotes ("origin" = source of truth, "github" = mirror).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PM="$REPO_ROOT/scripts/push-mirror.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m\n' "$1"; fail=$((fail+1)); fi; }

O="$T/origin.git"; G="$T/github.git"; R="$T/repo"
git init -q --bare "$O"; git init -q --bare "$G"
git init -q -b main "$R"
git -C "$R" config user.email t@t; git -C "$R" config user.name t; git -C "$R" config commit.gpgsign false
echo a >"$R/a"; git -C "$R" add a; git -C "$R" commit -qm one
git -C "$R" remote add origin "$O"; git -C "$R" remote add github "$G"
git -C "$R" push -q origin main; git -C "$R" push -q github main
echo b >"$R/b"; git -C "$R" add b; git -C "$R" commit -qm two
git -C "$R" tag -a flight-9.9.9 -m "flight 9.9.9" HEAD
git -C "$R" push -q origin main; git -C "$R" push -q origin flight-9.9.9
HEAD_SHA="$(git -C "$R" rev-parse HEAD)"
export PUSH_MIRROR_ROOT="$R"

# --- dry run ---
out="$("$PM" --dry-run)"
check "dry-run reports the fast-forward and the tag" "$(grep -q 'would push origin/main' <<<"$out" && grep -q 'would push tag flight-9.9.9' <<<"$out" && echo 1 || echo 0)"
check "dry-run moves nothing" "$([ "$(git -C "$G" rev-parse main)" != "$HEAD_SHA" ] && ! git -C "$G" rev-parse -q --verify refs/tags/flight-9.9.9 >/dev/null && echo 1 || echo 0)"

# --- real push ---
out="$("$PM")"
check "mirror main fast-forwarded to origin/main" "$([ "$(git -C "$G" rev-parse main)" = "$HEAD_SHA" ] && echo 1 || echo 0)"
check "tag at the head pushed to the mirror" "$([ "$(git -C "$G" rev-parse 'flight-9.9.9^{commit}')" = "$HEAD_SHA" ] && echo 1 || echo 0)"
check "reports one new commit" "$(grep -q '1 new commit' <<<"$out" && echo 1 || echo 0)"

# --- idempotent ---
out="$("$PM")"
check "second run: branch already there, tag already there, exit 0" "$(grep -q 'already at' <<<"$out" && grep -q 'already on github' <<<"$out" && echo 1 || echo 0)"

# --- mirror moved out of band → refuse, no force ---
M="$T/mirror-clone"; git clone -q "$G" "$M"; git -C "$M" config user.email x@x; git -C "$M" config user.name x; git -C "$M" config commit.gpgsign false
echo rogue >"$M/rogue"; git -C "$M" add rogue; git -C "$M" commit -qm rogue; git -C "$M" push -q origin main
ROGUE="$(git -C "$M" rev-parse HEAD)"
if "$PM" >/dev/null 2>"$T/refuse.err"; then rc=0; else rc=$?; fi
check "non-ancestor mirror → non-zero and a 'refusing to force-push' message" "$([ "$rc" != 0 ] && grep -q 'refusing to force-push' "$T/refuse.err" && echo 1 || echo 0)"
check "mirror left untouched" "$([ "$(git -C "$G" rev-parse main)" = "$ROGUE" ] && echo 1 || echo 0)"
git -C "$G" update-ref refs/heads/main "$HEAD_SHA"	# repair for the next cases

# --- multiple branches, branch missing on origin is skipped ---
git -C "$R" checkout -q -b qa; echo q >"$R/q"; git -C "$R" add q; git -C "$R" commit -qm qa; git -C "$R" push -q origin qa; git -C "$R" checkout -q main
out="$("$PM" --branch main --branch qa --branch nosuch 2>"$T/multi.err")" && rc=0 || rc=$?
check "--branch repeatable: qa pushed to the mirror (new branch)" "$([ "$(git -C "$G" rev-parse qa)" = "$(git -C "$R" rev-parse qa)" ] && echo 1 || echo 0)"
check "a branch missing on origin is skipped with a message and non-zero exit" "$([ "$rc" != 0 ] && grep -q 'no branch nosuch' "$T/multi.err" && echo 1 || echo 0)"

# --- guards ---
git -C "$R" remote remove github
if "$PM" --dry-run >/dev/null 2>"$T/nogh.err"; then rc=0; else rc=$?; fi
check "missing mirror remote errors clearly" "$([ "$rc" = 1 ] && grep -q "no 'github' remote" "$T/nogh.err" && echo 1 || echo 0)"
if "$PM" --bogus >/dev/null 2>&1; then rc=0; else rc=$?; fi
check "unknown argument errors" "$([ "$rc" != 0 ] && echo 1 || echo 0)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
