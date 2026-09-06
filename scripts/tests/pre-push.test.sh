#!/usr/bin/env bash
# Unit tests for .githooks/pre-push.
#
# git feeds the hook one line per ref on stdin:
#   <local ref> <local sha> <remote ref> <remote sha>
# The hook verifies signatures on exactly the commits each ref pushes
# (remote..local, or local --not --remotes=<remote> for a new branch), skips
# ref deletions, exits 0 without running anything when no commits are pushed,
# and then runs runChecks.sh with the signature check skipped.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK_SRC="$REPO_ROOT/.githooks/pre-push"

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m\n' "$1"; fail=$((fail+1)); fi; }

# Sandbox: a real git repo (the hook resolves REPO_ROOT via rev-parse) holding
# the hook plus stub runChecks.sh / verifyGitLogs.sh that record their calls.
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
git init -q "$SANDBOX"
mkdir -p "$SANDBOX/.githooks" "$SANDBOX/scripts/checks"
cp "$HOOK_SRC" "$SANDBOX/.githooks/pre-push"
chmod +x "$SANDBOX/.githooks/pre-push"
CHECKS_LOG="$SANDBOX/checks.log"
VERIFY_LOG="$SANDBOX/verify.log"
cat >"$SANDBOX/scripts/runChecks.sh" <<STUB
#!/usr/bin/env bash
printf 'RUNCHECKS_SKIP=%s\n' "\${RUNCHECKS_SKIP:-}" >>"$CHECKS_LOG"
exit "\${STUB_CHECKS_RC:-0}"
STUB
cat >"$SANDBOX/scripts/checks/verifyGitLogs.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$VERIFY_LOG"
exit "\${STUB_VERIFY_RC:-0}"
STUB
chmod +x "$SANDBOX/scripts/runChecks.sh" "$SANDBOX/scripts/checks/verifyGitLogs.sh"

ZERO="0000000000000000000000000000000000000000"
SHA_A="1111111111111111111111111111111111111111"
SHA_B="2222222222222222222222222222222222222222"

run_hook() {	# stdin is the ref list; git runs hooks from the repo top-level
	rm -f "$CHECKS_LOG" "$VERIFY_LOG"
	(cd "$SANDBOX" && ./.githooks/pre-push origin git@example.com:acme/widget.git)
}
checks_ran()  { [ -e "$CHECKS_LOG" ]; }
verify_args() { cat "$VERIFY_LOG" 2>/dev/null || true; }

# --- delete-only pushes run nothing ---
printf '(delete) %s refs/heads/feature/1-x %s\n' "$ZERO" "$SHA_A" | run_hook && rc=0 || rc=$?
check "delete-only push exits 0" "$([ "$rc" = 0 ] && echo 1 || echo 0)"
check "delete-only push runs neither checks nor signature verify" \
	"$(! checks_ran && [ -z "$(verify_args)" ] && echo 1 || echo 0)"

printf '(delete) %s refs/heads/feature/1-x %s\n(delete) %s refs/heads/feature/2-y %s\n' \
	"$ZERO" "$SHA_A" "$ZERO" "$SHA_B" | run_hook && rc=0 || rc=$?
check "multiple deletes still run nothing" "$([ "$rc" = 0 ] && ! checks_ran && echo 1 || echo 0)"

: | run_hook && rc=0 || rc=$?
check "empty ref list exits 0 without running anything" "$([ "$rc" = 0 ] && ! checks_ran && echo 1 || echo 0)"

# --- pushes that carry commits verify the exact range, then run the checks ---
printf 'refs/heads/develop %s refs/heads/develop %s\n' "$SHA_B" "$SHA_A" | run_hook && rc=0 || rc=$?
check "update push exits 0" "$([ "$rc" = 0 ] && echo 1 || echo 0)"
check "update push verifies remote..local" "$([ "$(verify_args)" = "$SHA_A..$SHA_B" ] && echo 1 || echo 0)"
check "update push runs the checks with verifyGitLogs.sh skipped" \
	"$(checks_ran && grep -q 'RUNCHECKS_SKIP=verifyGitLogs.sh' "$CHECKS_LOG" && echo 1 || echo 0)"

printf 'refs/heads/feature/3-z %s refs/heads/feature/3-z %s\n' "$SHA_A" "$ZERO" | run_hook && rc=0 || rc=$?
check "new-branch push verifies local --not --remotes=<remote>" \
	"$([ "$rc" = 0 ] && [ "$(verify_args)" = "$SHA_A --not --remotes=origin" ] && checks_ran && echo 1 || echo 0)"

printf '(delete) %s refs/heads/feature/1-x %s\nrefs/heads/develop %s refs/heads/develop %s\n' \
	"$ZERO" "$SHA_A" "$SHA_B" "$SHA_A" | run_hook && rc=0 || rc=$?
check "mixed delete + update verifies only the update and runs the checks" \
	"$([ "$rc" = 0 ] && [ "$(verify_args | wc -l)" = 1 ] && checks_ran && echo 1 || echo 0)"

# --- failures propagate ---
STUB_CHECKS_RC=3 bash -c 'cd "$3" && printf "refs/heads/develop %s refs/heads/develop %s\n" "$1" "$2" | ./.githooks/pre-push origin' \
	_ "$SHA_B" "$SHA_A" "$SANDBOX" && rc=0 || rc=$?
check "failing checks make the hook fail" "$([ "$rc" = 3 ] && echo 1 || echo 0)"

rm -f "$CHECKS_LOG"
STUB_VERIFY_RC=1 bash -c 'cd "$3" && printf "refs/heads/develop %s refs/heads/develop %s\n" "$1" "$2" | ./.githooks/pre-push origin' \
	_ "$SHA_B" "$SHA_A" "$SANDBOX" && rc=0 || rc=$?
check "a bad signature fails the hook before the checks run" "$([ "$rc" != 0 ] && ! checks_ran && echo 1 || echo 0)"

# --- sibling worktrees on branches without scripts/ are left alone ---
chmod -x "$SANDBOX/scripts/runChecks.sh"
printf 'refs/heads/develop %s refs/heads/develop %s\n' "$SHA_B" "$SHA_A" | run_hook && rc=0 || rc=$?
check "exits 0 without verifying when runChecks.sh is not executable" \
	"$([ "$rc" = 0 ] && [ -z "$(verify_args)" ] && echo 1 || echo 0)"
chmod +x "$SANDBOX/scripts/runChecks.sh"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
