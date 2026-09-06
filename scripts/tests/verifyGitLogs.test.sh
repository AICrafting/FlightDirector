#!/usr/bin/env bash
# Unit tests for scripts/checks/verifyGitLogs.sh — argument modes and the
# empty-selection / empty-repo guards. Signature *validity* itself is not
# tested here (it needs a signing key); unsigned commits are used to show
# that a selected commit is actually inspected.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERIFY_SRC="$REPO_ROOT/scripts/checks/verifyGitLogs.sh"

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m\n' "$1"; fail=$((fail+1)); fi; }

# The script cd's to "$(dirname "$0")/../..", so stage it at the same depth
# inside a sandbox repo.
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
git init -q "$SANDBOX"
git -C "$SANDBOX" config user.email test@example.com
git -C "$SANDBOX" config user.name test
git -C "$SANDBOX" config commit.gpgsign false
mkdir -p "$SANDBOX/scripts/checks"
cp "$VERIFY_SRC" "$SANDBOX/scripts/checks/verifyGitLogs.sh"
chmod +x "$SANDBOX/scripts/checks/verifyGitLogs.sh"
VERIFY="$SANDBOX/scripts/checks/verifyGitLogs.sh"

# --- empty repo ---
out="$("$VERIFY" 2>&1)" && rc=0 || rc=$?
check "empty repo exits 0" "$([ "$rc" = 0 ] && echo 1 || echo 0)"
check "empty repo says there is nothing to verify" "$(grep -q 'No commits yet' <<<"$out" && echo 1 || echo 0)"

# --- unsigned commits are inspected and rejected ---
echo a >"$SANDBOX/a"; git -C "$SANDBOX" add a; git -C "$SANDBOX" commit -q -m one
echo b >"$SANDBOX/b"; git -C "$SANDBOX" add b; git -C "$SANDBOX" commit -q -m two
FIRST="$(git -C "$SANDBOX" rev-parse HEAD~1)"

"$VERIFY" 1 >/dev/null 2>&1 && rc=0 || rc=$?
check "count mode inspects commits (unsigned → fail)" "$([ "$rc" = 1 ] && echo 1 || echo 0)"

out="$("$VERIFY" "$FIRST..HEAD" 2>&1)" && rc=0 || rc=$?
check "rev-list range mode inspects exactly that range" \
	"$([ "$rc" = 1 ] && grep -q '1 of 1 commit' <<<"$out" && echo 1 || echo 0)"

out="$("$VERIFY" HEAD --not --remotes 2>&1)" && rc=0 || rc=$?
check "rev-list mode accepts multiple arguments (HEAD --not --remotes)" \
	"$([ "$rc" = 1 ] && grep -q '2 of 2 commit' <<<"$out" && echo 1 || echo 0)"

# --- empty selection ---
out="$("$VERIFY" HEAD..HEAD 2>&1)" && rc=0 || rc=$?
check "empty rev-list selection exits 0" "$([ "$rc" = 0 ] && grep -q 'No commits to verify' <<<"$out" && echo 1 || echo 0)"

# --- bad count still rejected ---
"$VERIFY" 0 >/dev/null 2>&1 && rc=0 || rc=$?
check "count of 0 is rejected with exit 2" "$([ "$rc" = 2 ] && echo 1 || echo 0)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
