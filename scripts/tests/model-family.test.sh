#!/usr/bin/env bash
# Unit tests for dispatcher-owned model-family derivation and label creation.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FLIGHT="$REPO_ROOT/flight/scripts/flight"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0
fail=0

check_family() {
	id="$1"
	want="$2"
	name="$3"
	if got="$($FLIGHT labels model-family --id "$id" 2>"$SANDBOX/stderr")" && [ "$got" = "$want" ]; then
		printf '\033[0;32m  ✓ %s\033[0m\n' "$name"
		pass=$((pass + 1))
	else
		printf '\033[0;31m  ✗ %s (want=%s got=%s)\033[0m\n' "$name" "$want" "${got:-<error>}"
		fail=$((fail + 1))
	fi
}

check_family gpt-5.6-sol sol 'gpt codename uses the last segment'
check_family gpt-6-astra astra 'gpt major version codename uses the last segment'
check_family gpt-5.6 gpt-5.6 'gpt without a codename stays explicit'
check_family claude-opus-4.7 opus 'claude dotted version uses its family'
check_family claude-fable-5-1 fable 'claude segmented version uses its family'
check_family us.anthropic.claude-sonnet-4.5 sonnet 'dot vendor prefix is stripped'
check_family openai/gpt-5.6-terra terra 'slash vendor prefix is stripped'

if "$FLIGHT" labels model-family --id codex-auto-review >"$SANDBOX/service.out" 2>"$SANDBOX/service.err"; then
	printf '\033[0;31m  ✗ service ids are rejected\033[0m\n'
	fail=$((fail + 1))
elif [ ! -s "$SANDBOX/service.out" ] && grep -qi 'not a worked-by model' "$SANDBOX/service.err"; then
	printf '\033[0;32m  ✓ service ids are rejected\033[0m\n'
	pass=$((pass + 1))
else
	printf '\033[0;31m  ✗ service-id rejection explains why it was skipped\033[0m\n'
	fail=$((fail + 1))
fi

if got="$($FLIGHT labels model-family --id 'Acme Model@Preview' 2>"$SANDBOX/unknown.err")" \
	&& [ "$got" = acme-model-preview ] \
	&& grep -qi 'unrecognised' "$SANDBOX/unknown.err"; then
	printf '\033[0;32m  ✓ unknown ids are sanitized with a warning\033[0m\n'
	pass=$((pass + 1))
else
	printf '\033[0;31m  ✗ unknown ids use the documented fallback\033[0m\n'
	fail=$((fail + 1))
fi

if got="$($FLIGHT labels model-family --id gpt-5beta 2>"$SANDBOX/malformed.err")" \
	&& [ "$got" = gpt-5beta ] \
	&& grep -qi 'unrecognised' "$SANDBOX/malformed.err"; then
	printf '\033[0;32m  ✓ malformed lookalikes use the warned fallback\033[0m\n'
	pass=$((pass + 1))
else
	printf '\033[0;31m  ✗ malformed lookalikes are not treated as recognized models\033[0m\n'
	fail=$((fail + 1))
fi

mkdir -p "$SANDBOX/repo/.flightdirector" "$SANDBOX/bin"
printf '%s\n' '{"code":{"backend":"forgejo","api":"https://forge.invalid/api/v1","owner":"o","repo":"r"}}' >"$SANDBOX/repo/.flightdirector/config.json"
printf '%s\n' '{"code":{"token":"t"}}' >"$SANDBOX/repo/.flightdirector/secrets.json"
git -C "$SANDBOX/repo" init -q

cat >"$SANDBOX/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""; method=GET; payload=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-w) shift 2 ;;
		-X) method="$2"; shift 2 ;;
		-H) shift 2 ;;
		--data-binary) payload="$2"; shift 2 ;;
		*) shift ;;
	esac
done
if [ "$method" = GET ]; then
	printf '%s' '[]' >"$out"
else
	printf '%s' '{"id":9}' >"$out"
	printf '%s' "$payload" >"${CURL_PAYLOAD:?}"
fi
printf '200'
SH
chmod +x "$SANDBOX/bin/curl"

if got="$(cd "$SANDBOX/repo" && PATH="$SANDBOX/bin:$PATH" CURL_PAYLOAD="$SANDBOX/payload" "$FLIGHT" labels ensure --model gpt-5.6-sol)" \
	&& [ "$got" = 9 ] \
	&& jq -e '.name == "model/sol" and .color == "#d97757" and .description == "Issue was worked on using Sol"' "$SANDBOX/payload" >/dev/null; then
	printf '\033[0;32m  ✓ ensure --model derives standard label metadata\033[0m\n'
	pass=$((pass + 1))
else
	printf '\033[0;31m  ✗ ensure --model derives standard label metadata\033[0m\n'
	fail=$((fail + 1))
fi

printf '\nPassed: %d  Failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
