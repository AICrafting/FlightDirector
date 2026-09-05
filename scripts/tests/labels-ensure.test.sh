#!/usr/bin/env bash
# Unit tests for the idempotent `labels ensure` adapter contract.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ADAPTER="$REPO_ROOT/flight/scripts/adapters/forgejo/labels"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""; method=GET; url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-w) shift 2 ;;
		-X) method="$2"; shift 2 ;;
		-H|--data-binary) shift 2 ;;
		*) url="$1"; shift ;;
	esac
done
if [ "$method" = GET ]; then
	if [ "${LABEL_EXISTS:-0}" = 1 ]; then
		printf '%s' '[{"id":7,"name":"model/sol","color":"d97757","description":"existing"}]' >"$out"
	else
		printf '%s' '[]' >"$out"
	fi
else
	printf '%s' '{"id":9}' >"$out"
	printf '%s\n' POST >>"${CURL_LOG:?}"
fi
printf '200'
SH
chmod +x "$SANDBOX/bin/curl"

export PATH="$SANDBOX/bin:$PATH"
export LS_API=https://forge.invalid/api/v1 LS_OWNER=o LS_REPO=r LS_TOKEN=t
export CURL_LOG="$SANDBOX/curl.log"

LABEL_EXISTS=1 "$ADAPTER" ensure --name model/sol --color '#d97757' --description new >"$SANDBOX/existing"
[ "$(cat "$SANDBOX/existing")" = 7 ]
[ ! -s "$CURL_LOG" ]

LABEL_EXISTS=0 "$ADAPTER" ensure --name model/sol --color '#d97757' --description new >"$SANDBOX/missing"
[ "$(cat "$SANDBOX/missing")" = 9 ]
[ "$(wc -l <"$CURL_LOG")" -eq 1 ]

printf 'labels ensure tests passed\n'
