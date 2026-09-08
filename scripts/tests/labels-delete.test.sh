#!/usr/bin/env bash
# Contract tests for `labels delete` (#111): refuses while in use, --force overrides,
# unknown names error, Jira always errors.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"

# Fake curl: label pages come from a fixed list; issue/MR queries return IN_USE rows;
# every non-GET request is logged as method<TAB>url.
cat >"$SANDBOX/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
out=""; method=GET; url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-w|-X|-H|-u|--data-binary) [ "$1" = -X ] && method="$2"; shift 2 ;;
		-L|-sS) shift ;;
		*) url="$1"; shift ;;
	esac
done
if [ "$method" = GET ]; then
	case "$url" in
		*/labels\?*page=1*) printf '%s' '[{"id":7,"name":"model/gpt-5","color":"d97757","description":"old"},{"id":8,"name":"status/in progress","color":"1f9d55"}]' >"$out" ;;
		*/labels\?*) printf '%s' '[]' >"$out" ;;
		*/issues\?*|*/merge_requests\?*)
			printf '%s\t%s\n' "$method" "$url" >>"${CURL_LOG:?}"
			jq -n --argjson n "${IN_USE:-0}" '[range($n) | {number: ., iid: .}]' >"$out" ;;
		*) printf '%s' '[]' >"$out" ;;
	esac
else
	printf '%s' '{}' >"$out"
	printf '%s\t%s\n' "$method" "$url" >>"${CURL_LOG:?}"
fi
printf '200'
CURL
chmod +x "$SANDBOX/bin/curl"

export PATH="$SANDBOX/bin:$PATH"
export LS_API=https://example.invalid/api LS_OWNER=acme LS_REPO=widget LS_TOKEN=t
export CURL_LOG="$SANDBOX/curl.log"

pass=0; fail=0
ok()     { pass=$((pass+1)); printf '  ✓ %s\n' "$1"; }
not_ok() { fail=$((fail+1)); printf '  ✗ %s\n' "$1"; }
check()  { if [ "$2" = 1 ]; then ok "$1"; else not_ok "$1"; fi; }

run() { # backend args… → sets RC, ERR
	backend="$1"; shift
	: >"$CURL_LOG"
	if "$REPO_ROOT/flight/scripts/adapters/$backend/labels" delete "$@" >"$SANDBOX/out" 2>"$SANDBOX/err"; then RC=0; else RC=$?; fi
	ERR="$(cat "$SANDBOX/err")"
}
deleted() { grep -Eq "^DELETE	$1\$" "$CURL_LOG"; }

# --- forgejo -------------------------------------------------------------
IN_USE=3 run forgejo --name model/gpt-5
check "forgejo: refuses while in use (exit 1)" "$([ "$RC" = 1 ] && echo 1 || echo 0)"
check "forgejo: refusal names the count and --force" "$(printf '%s' "$ERR" | grep -q "3 issue" && printf '%s' "$ERR" | grep -q -- '--force' && echo 1 || echo 0)"
check "forgejo: in-use probe spans issues+PRs, all states, by name" "$(grep -Eq $'^GET\thttps://example.invalid/api/repos/acme/widget/issues\\?state=all&labels=model%2Fgpt-5&limit=50$' "$CURL_LOG" && echo 1 || echo 0)"
check "forgejo: nothing deleted on refusal" "$(deleted 'https://example.invalid/api/repos/acme/widget/labels/7' && echo 0 || echo 1)"

IN_USE=3 run forgejo --name model/gpt-5 --force
check "forgejo: --force deletes by id, silent" "$([ "$RC" = 0 ] && [ ! -s "$SANDBOX/out" ] && deleted 'https://example.invalid/api/repos/acme/widget/labels/7' && echo 1 || echo 0)"
check "forgejo: --force skips the in-use probe" "$(grep -q '/issues?' "$CURL_LOG" && echo 0 || echo 1)"

IN_USE=0 run forgejo --name model/gpt-5
check "forgejo: deletes when unused" "$([ "$RC" = 0 ] && deleted 'https://example.invalid/api/repos/acme/widget/labels/7' && echo 1 || echo 0)"

IN_USE=50 run forgejo --name "status/in progress"
check "forgejo: full page reports 50+ (name url-encoded incl. space)" "$([ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q '50+ issue' && grep -q 'labels=status%2Fin%20progress' "$CURL_LOG" && echo 1 || echo 0)"

run forgejo --name nope
check "forgejo: unknown label name errors, no requests beyond the label list" "$([ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q "not found" && [ ! -s "$CURL_LOG" ] && echo 1 || echo 0)"

run forgejo
check "forgejo: --name is required" "$([ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q -- '--name required' && echo 1 || echo 0)"

# --- github --------------------------------------------------------------
IN_USE=2 run github --name model/gpt-5
check "github: refuses while in use" "$([ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q '2 issue' && echo 1 || echo 0)"
check "github: probe uses state=all + encoded labels" "$(grep -Eq $'^GET\thttps://example.invalid/api/repos/acme/widget/issues\\?state=all&labels=model%2Fgpt-5&per_page=50$' "$CURL_LOG" && echo 1 || echo 0)"
IN_USE=0 run github --name model/gpt-5
check "github: deletes by encoded name" "$([ "$RC" = 0 ] && deleted 'https://example.invalid/api/repos/acme/widget/labels/model%2Fgpt-5' && echo 1 || echo 0)"
IN_USE=2 run github --name model/gpt-5 --force
check "github: --force deletes" "$([ "$RC" = 0 ] && deleted 'https://example.invalid/api/repos/acme/widget/labels/model%2Fgpt-5' && echo 1 || echo 0)"
run github --name nope
check "github: unknown name errors" "$([ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'not found' && echo 1 || echo 0)"

# --- gitlab --------------------------------------------------------------
IN_USE=2 run gitlab --name model/gpt-5
check "gitlab: refuses; issues + MRs are summed" "$([ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q '4 issue' && echo 1 || echo 0)"
check "gitlab: probes both /issues and /merge_requests" "$(grep -q 'projects/acme%2Fwidget/issues?labels=model%2Fgpt-5' "$CURL_LOG" && grep -q 'projects/acme%2Fwidget/merge_requests?labels=model%2Fgpt-5' "$CURL_LOG" && echo 1 || echo 0)"
IN_USE=0 run gitlab --name model/gpt-5
check "gitlab: deletes by encoded name" "$([ "$RC" = 0 ] && deleted 'https://example.invalid/api/projects/acme%2Fwidget/labels/model%2Fgpt-5' && echo 1 || echo 0)"
IN_USE=2 run gitlab --name model/gpt-5 --force
check "gitlab: --force deletes" "$([ "$RC" = 0 ] && deleted 'https://example.invalid/api/projects/acme%2Fwidget/labels/model%2Fgpt-5' && echo 1 || echo 0)"

# --- jira ----------------------------------------------------------------
export LS_EMAIL=dev@example.invalid LS_PROJECT=ACME
run jira --name model/gpt-5
check "jira: always errors and points at issues label-remove" "$([ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'label-remove' && [ ! -s "$CURL_LOG" ] && echo 1 || echo 0)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
