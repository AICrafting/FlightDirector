#!/usr/bin/env bash
# Contract tests for rename-in-place label editing across supported backends.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"

cat >"$SANDBOX/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""; method=GET; payload=""; url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-w) shift 2 ;;
		-X) method="$2"; shift 2 ;;
		-H|-u) shift 2 ;;
		-L|-sS) shift ;;
		--data-binary) payload="$2"; shift 2 ;;
		*) url="$1"; shift ;;
	esac
done
if [ "$method" = GET ]; then
	if [ "${FORGEJO_PAGE_TWO:-0}" = 1 ]; then
		case "$url" in
			*page=1) jq -n '[range(50) | {id: ., name: ("first-" + tostring)}]' >"$out" ;;
			*page=2) jq -n '[range(49) | {id: (100 + .), name: ("second-" + tostring)}] + [{id:7,name:"model/gpt-5",color:"d97757",description:"old"}]' >"$out" ;;
			*) printf '%s' '[]' >"$out" ;;
		esac
	else
		case "$url" in
			*page=1) printf '%s' '[{"id":7,"name":"model/gpt-5","color":"d97757","description":"old"}]' >"$out" ;;
			*) printf '%s' '[]' >"$out" ;;
		esac
	fi
else
	printf '%s' '{"id":7}' >"$out"
	printf '%s\t%s\t%s\n' "$method" "$url" "$payload" >>"${CURL_LOG:?}"
fi
printf '200'
SH
chmod +x "$SANDBOX/bin/curl"

export PATH="$SANDBOX/bin:$PATH"
export LS_API=https://example.invalid/api LS_OWNER=acme LS_REPO=widget LS_TOKEN=t
export CURL_LOG="$SANDBOX/curl.log"

run_edit() {
	backend="$1"
	: >"$CURL_LOG"
	"$REPO_ROOT/flight/scripts/adapters/$backend/labels" edit \
		--name model/gpt-5 --new-name model/sol >"$SANDBOX/$backend.out"
}

run_edit forgejo
[ "$(cat "$SANDBOX/forgejo.out")" = 7 ]
grep -Eq $'^PATCH\thttps://example.invalid/api/repos/acme/widget/labels/7\t' "$CURL_LOG"
[ "$(cut -f3 "$CURL_LOG" | jq -r .name)" = model/sol ]

FORGEJO_PAGE_TWO=1 run_edit forgejo
[ "$(cat "$SANDBOX/forgejo.out")" = 7 ]
[ "$(cut -f3 "$CURL_LOG" | jq -r .name)" = model/sol ]

run_edit github
[ "$(cat "$SANDBOX/github.out")" = 7 ]
grep -Eq $'^PATCH\thttps://example.invalid/api/repos/acme/widget/labels/model%2Fgpt-5\t' "$CURL_LOG"
[ "$(cut -f3 "$CURL_LOG" | jq -r .new_name)" = model/sol ]

run_edit gitlab
[ "$(cat "$SANDBOX/gitlab.out")" = 7 ]
grep -Eq $'^PUT\thttps://example.invalid/api/projects/acme%2Fwidget/labels/model%2Fgpt-5\t' "$CURL_LOG"
[ "$(cut -f3 "$CURL_LOG" | jq -r .new_name)" = model/sol ]

export LS_EMAIL=dev@example.invalid LS_PROJECT=ACME
if "$REPO_ROOT/flight/scripts/adapters/jira/labels" edit \
	--name model/gpt-5 --new-name model/sol >"$SANDBOX/jira.out" 2>"$SANDBOX/jira.err"; then
	printf 'jira edit unexpectedly succeeded\n' >&2
	exit 1
fi
grep -qi 'free text' "$SANDBOX/jira.err"

printf 'labels edit tests passed\n'
