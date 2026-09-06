#!/usr/bin/env bash
# Unit tests for .githooks/pre-push — the guard that skips the check scripts
# when a push carries no commits (branch deletions).
#
# git feeds the hook one line per ref on stdin:
#   <local ref> <local sha> <remote ref> <remote sha>
# A delete has local ref "(delete)" and an all-zero local sha.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK_SRC="$REPO_ROOT/.githooks/pre-push"

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m\n' "$1"; fail=$((fail+1)); fi; }

# Sandbox: the hook resolves REPO_ROOT relative to its own path, so stage a
# fake repo with a stub runChecks.sh that records whether it was invoked.
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/.githooks" "$SANDBOX/scripts"
cp "$HOOK_SRC" "$SANDBOX/.githooks/pre-push"
chmod +x "$SANDBOX/.githooks/pre-push"
MARKER="$SANDBOX/ran"
cat >"$SANDBOX/scripts/runChecks.sh" <<STUB
#!/usr/bin/env bash
touch "$MARKER"
exit 0
STUB
chmod +x "$SANDBOX/scripts/runChecks.sh"

HOOK="$SANDBOX/.githooks/pre-push"
ZERO="0000000000000000000000000000000000000000"
SHA_A="1111111111111111111111111111111111111111"
SHA_B="2222222222222222222222222222222222222222"

run_hook() {	# stdin is the ref list; returns the hook's exit code
	rm -f "$MARKER"
	"$HOOK" origin git@example.com:acme/widget.git
}

# --- delete-only pushes skip the checks ---
printf '(delete) %s refs/heads/feature/1-x %s\n' "$ZERO" "$SHA_A" | run_hook && rc=0 || rc=$?
check "delete-only push exits 0" "$([ "$rc" = 0 ] && echo 1 || echo 0)"
check "delete-only push does not run the checks" "$([ ! -e "$MARKER" ] && echo 1 || echo 0)"

printf '(delete) %s refs/heads/feature/1-x %s\n(delete) %s refs/heads/feature/2-y %s\n' \
	"$ZERO" "$SHA_A" "$ZERO" "$SHA_B" | run_hook && rc=0 || rc=$?
check "multiple deletes still skip the checks" "$([ "$rc" = 0 ] && [ ! -e "$MARKER" ] && echo 1 || echo 0)"

# --- anything that pushes commits runs the checks ---
printf 'refs/heads/develop %s refs/heads/develop %s\n' "$SHA_A" "$SHA_B" | run_hook && rc=0 || rc=$?
check "update push runs the checks" "$([ "$rc" = 0 ] && [ -e "$MARKER" ] && echo 1 || echo 0)"

printf 'refs/heads/feature/3-z %s refs/heads/feature/3-z %s\n' "$SHA_A" "$ZERO" | run_hook && rc=0 || rc=$?
check "new-branch push (zero remote sha) runs the checks" "$([ "$rc" = 0 ] && [ -e "$MARKER" ] && echo 1 || echo 0)"

printf '(delete) %s refs/heads/feature/1-x %s\nrefs/heads/develop %s refs/heads/develop %s\n' \
	"$ZERO" "$SHA_A" "$SHA_A" "$SHA_B" | run_hook && rc=0 || rc=$?
check "mixed delete + update runs the checks" "$([ "$rc" = 0 ] && [ -e "$MARKER" ] && echo 1 || echo 0)"

# --- no refs at all (nothing to push) skips ---
: | run_hook && rc=0 || rc=$?
check "empty ref list exits 0 without running the checks" "$([ "$rc" = 0 ] && [ ! -e "$MARKER" ] && echo 1 || echo 0)"

# --- the checks' exit code still propagates ---
cat >"$SANDBOX/scripts/runChecks.sh" <<STUB
#!/usr/bin/env bash
touch "$MARKER"
exit 3
STUB
printf 'refs/heads/develop %s refs/heads/develop %s\n' "$SHA_A" "$SHA_B" | run_hook && rc=0 || rc=$?
check "failing checks make the hook fail" "$([ "$rc" = 3 ] && echo 1 || echo 0)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
