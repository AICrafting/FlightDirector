#!/usr/bin/env bash
# `flight issues attach --check` (FJ-311): a skill asks whether the tracker can take an
# upload before it writes a body around the URL. Forgejo and GitLab can (exit 0, nothing
# sent); GitHub and Jira can't, and fail with the `unsupported` code. Offline: --check
# never reaches the network, and curl is replaced by a stub that records any call.
set -euo pipefail

unset LS_TOKEN FLIGHT_TOKEN FORGEJO_TOKEN LS_SECRETS_FILE LS_EMAIL FLIGHT_ERROR_FILE LS_JSON
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$REPO_ROOT/flight/scripts/flight"
ADAPTERS="$REPO_ROOT/flight/scripts/adapters"
SKILL="$REPO_ROOT/flight/skills/filing-issues/SKILL.md"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0; fail=0
check() {
	if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass + 1))
	else printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail + 1)); fi
}
section() { printf '\033[1m── %s ──\033[0m\n' "$1"; }
yes_if() { if "$@"; then echo 1; else echo 0; fi; }

# A curl that records being called, so "nothing is sent" is checked, not assumed.
mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/curl" <<SH
#!/usr/bin/env bash
echo "\$*" >>"$SANDBOX/curl.log"
exit 7
SH
chmod +x "$SANDBOX/bin/curl"

# attach BACKEND ARGS… — run the adapter's attach verb offline; sets RC, OUT, ERR, CODE.
attach() {
	local backend="$1"; shift
	local ef="$SANDBOX/errfile"
	rm -f "$ef" "$SANDBOX/curl.log"
	RC=0
	env PATH="$SANDBOX/bin:$PATH" FLIGHT_ERROR_FILE="$ef" \
		LS_API=https://forge.invalid/api/v1 LS_OWNER=o LS_REPO=r LS_TOKEN=t \
		LS_PROJECT=ACME LS_EMAIL=a@b.c \
		"$ADAPTERS/$backend/issues" attach "$@" >"$SANDBOX/out" 2>"$SANDBOX/err" || RC=$?
	OUT="$(cat "$SANDBOX/out")"
	ERR="$(cat "$SANDBOX/err")"
	CODE="$(jq -r '.error.code' "$ef" 2>/dev/null || true)"
}

section "backends that can upload"
for b in forgejo gitlab; do
	attach "$b" --check
	check "$b: --check exits 0" "$(yes_if [ "$RC" = 0 ])" "rc=$RC $ERR"
	check "$b: --check prints nothing" "$(yes_if [ -z "$OUT$ERR" ])" "$OUT$ERR"
	check "$b: --check sends nothing" "$(yes_if [ ! -e "$SANDBOX/curl.log" ])"
	attach "$b" --file /nonexistent
	check "$b: an upload still needs --number (usage)" "$(yes_if [ "$RC" != 0 ] && [ "$CODE" = usage ])" "rc=$RC code=$CODE"
done

section "backends that can't"
for b in github jira; do
	attach "$b" --check
	check "$b: --check fails" "$(yes_if [ "$RC" != 0 ])"
	check "$b: --check reports unsupported" "$(yes_if [ "$CODE" = unsupported ])" "code=$CODE"
	check "$b: --check sends nothing" "$(yes_if [ ! -e "$SANDBOX/curl.log" ])"
	attach "$b" --number 1 --file "$SANDBOX/bin/curl"
	check "$b: an upload reports unsupported" "$(yes_if [ "$RC" != 0 ] && [ "$CODE" = unsupported ])" "rc=$RC code=$CODE"
	check "$b: and says why on stderr" "$(yes_if grep -q 'not supported' <<<"$ERR")" "$ERR"
done

section "dispatcher"
check "the capability token is advertised" "$(yes_if grep -qx issues-attach-check <<<"$("$DISP" capabilities)")"

section "filing-issues Step 7"
step7="$(sed -n '/^## Step 7/,/^## Step 8/p' "$SKILL")"
check "asks the tracker with --check before uploading" \
	"$(yes_if grep -q 'issues attach --tracker "$TRACKER" --check' <<<"$step7")"
check "names GitHub as unable to upload" "$(yes_if grep -q 'GitHub cannot' <<<"$step7")"
check "the upload is the condition of the branch that embeds its link" \
	"$(yes_if grep -q '^elif URL="$(flight issues attach' <<<"$step7")"

echo
echo "issues-attach: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
