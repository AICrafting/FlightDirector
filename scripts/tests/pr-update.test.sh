#!/usr/bin/env bash
# Contract tests for `pr update` (patch an open PR) and `pr get` (read one back)
# across every backend that has a `pr` adapter. A fake curl stands in for the API.
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
# One PR, in both the Forgejo/GitHub and the GitLab field spellings.
printf '%s' '{"number":42,"iid":42,"title":"Promote develop → qa","state":"open",
	"html_url":"https://example.invalid/acme/widget/pulls/42",
	"web_url":"https://example.invalid/acme/widget/-/merge_requests/42"}' >"$out"
if [ "$method" != GET ]; then
	# One line per write: METHOD⇥url⇥compacted-payload (adapters send pretty JSON).
	printf '%s\t%s\t%s\n' "$method" "$url" "$(printf '%s' "$payload" | jq -c . 2>/dev/null)" >>"${CURL_LOG:?}"
fi
printf '200'
SH
chmod +x "$SANDBOX/bin/curl"

export PATH="$SANDBOX/bin:$PATH"
export LS_API=https://example.invalid/api LS_OWNER=acme LS_REPO=widget LS_TOKEN=t
export CURL_LOG="$SANDBOX/curl.log"

printf 'Corrected test plan.\nSecond line.\n' >"$SANDBOX/body.md"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; }
bad() { fail=$((fail + 1)); printf '\033[0;31m  ✗ %s\033[0m\n' "$1"; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

# run <backend> <verb> [args…] — returns the adapter's exit code, resets the log.
run() {
	backend="$1"; verb="$2"; shift 2
	: >"$CURL_LOG"
	set +e
	"$REPO_ROOT/flight/scripts/adapters/$backend/pr" "$verb" "$@" \
		>"$SANDBOX/out" 2>"$SANDBOX/err"
	rc=$?
	set -e
	return $rc
}

payload() { cut -f3 "$CURL_LOG"; }

# --- pr update: only the fields passed are patched -------------------------
# backend | expected METHOD | expected API URL | body field name | expected web url
while IFS='|' read -r backend method url bodykey web_url; do
	[ -n "$backend" ] || continue

	if run "$backend" update --number 42 --title 'Fixed title'; then
		check "$(cut -f1,2 "$CURL_LOG")" "$(printf '%s\t%s' "$method" "$url")" \
			"$backend pr update patches the PR ($method)"
		check "$(payload | jq -r .title)" "Fixed title" "$backend sends the new title"
		check "$(payload | jq -r "has(\"$bodykey\")")" "false" \
			"$backend does not clobber the body on a title-only update"
		check "$(cat "$SANDBOX/out")" "" "$backend pr update is silent on success"
	else
		bad "$backend pr update --title exited non-zero"
	fi

	if run "$backend" update --number 42 --body 'New body'; then
		check "$(payload | jq -r ".$bodykey")" "New body" "$backend sends the new body"
		check "$(payload | jq -r 'has("title")')" "false" \
			"$backend does not clobber the title on a body-only update"
	else
		bad "$backend pr update --body exited non-zero"
	fi

	# --body-file keeps multi-line markdown intact.
	if run "$backend" update --number 42 --body-file "$SANDBOX/body.md"; then
		check "$(payload | jq -r ".$bodykey")" "$(cat "$SANDBOX/body.md")" \
			"$backend --body-file preserves multi-line markdown"
	else
		bad "$backend pr update --body-file exited non-zero"
	fi

	# Both at once.
	if run "$backend" update --number 42 --title T --body B; then
		check "$(payload | jq -c "[.title, .$bodykey]")" '["T","B"]' \
			"$backend patches title and body together"
	else
		bad "$backend pr update --title --body exited non-zero"
	fi

	# --- guard rails ---
	if run "$backend" update --title T; then
		bad "$backend pr update accepted no --number"
	else
		ok "$backend pr update requires --number"
	fi

	if run "$backend" update --number 42; then
		bad "$backend pr update accepted an empty patch"
	else
		check "$(grep -c . "$CURL_LOG")" "0" "$backend pr update with no fields writes nothing"
		ok "$backend pr update rejects an empty patch"
	fi

	if run "$backend" update --number 42 --body-file "$SANDBOX/missing.md"; then
		bad "$backend pr update accepted a missing --body-file"
	else
		ok "$backend pr update rejects a missing --body-file"
	fi

	# --- pr get ---
	if run "$backend" get --number 42; then
		check "$(cat "$SANDBOX/out")" \
			"$(printf '42\tPromote develop → qa\topen\t%s' "$web_url")" \
			"$backend pr get emits number⇥title⇥state⇥url"
		check "$(grep -c . "$CURL_LOG")" "0" "$backend pr get writes nothing"
	else
		bad "$backend pr get exited non-zero"
	fi

	if run "$backend" get; then
		bad "$backend pr get accepted no --number"
	else
		ok "$backend pr get requires --number"
	fi
done <<ROWS
forgejo|PATCH|https://example.invalid/api/repos/acme/widget/pulls/42|body|https://example.invalid/acme/widget/pulls/42
github|PATCH|https://example.invalid/api/repos/acme/widget/pulls/42|body|https://example.invalid/acme/widget/pulls/42
gitlab|PUT|https://example.invalid/api/projects/acme%2Fwidget/merge_requests/42|description|https://example.invalid/acme/widget/-/merge_requests/42
ROWS

# --- jira has no `pr` adapter at all: the dispatcher must refuse the axis ---
if [ -e "$REPO_ROOT/flight/scripts/adapters/jira/pr" ]; then
	bad "jira grew a pr adapter — Jira is issues-axis-only"
else
	ok "jira has no pr adapter (issues-axis-only backend)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
