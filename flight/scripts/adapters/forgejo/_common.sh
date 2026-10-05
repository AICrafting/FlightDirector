#!/usr/bin/env bash
#
# Shared helpers for the Forgejo adapter — sourced by issues/pr/ci/labels.
# Consumes the LS_* environment exported by the dispatcher; never reads config.
# shellcheck shell=bash

# Windows shims (jq CRLF, path form); a no-op elsewhere.
# shellcheck source-path=SCRIPTDIR source=../../_portable.sh
source "${BASH_SOURCE[0]%/*}/../../_portable.sh"
# shellcheck source-path=SCRIPTDIR source=../_errors.sh
source "${BASH_SOURCE[0]%/*}/../_errors.sh"
# shellcheck source-path=SCRIPTDIR source=../_json.sh
source "${BASH_SOURCE[0]%/*}/../_json.sh"

command -v curl >/dev/null 2>&1 || { echo "forgejo adapter: curl is required" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "forgejo adapter: jq is required" >&2; exit 1; }

require_env LS_API not-configured "LS_API not set (dispatcher must export it)"
require_env LS_OWNER not-configured "LS_OWNER not set"
require_env LS_REPO not-configured "LS_REPO not set"
require_env LS_TOKEN auth "LS_TOKEN not set — no token resolved for this axis"

REPO_API="${LS_API%/}/repos/${LS_OWNER}/${LS_REPO}"

warn() { echo "${ADAPTER_NAME:-forgejo}: warning: $*" >&2; }

# `urlenc` comes from ../../_portable.sh — every value interpolated into a URL
# goes through it. See the "URL encoding" rule in ../../../references/adapter-contract.md.

# _api METHOD PATH [JSON_DATA] — stdout is the response body; exits nonzero on HTTP >= 400.
# When _API_HEADER_FILE names a file, the response headers are dumped there as well
# (that is how _paged_get reads the row total). The flag is omitted when it is unset,
# so an ordinary call remains the plain curl it always was.
_api() {
  local method="$1" path="$2" data="${3:-}" tmp code msg
  local dump=()
  [ -z "${_API_HEADER_FILE:-}" ] || dump=(-D "$_API_HEADER_FILE")
  tmp="$(mktemp)"
  if [ -n "$data" ]; then
    code="$(curl -sS ${dump[@]+"${dump[@]}"} -o "$tmp" -w '%{http_code}' -X "$method" \
      -H "Authorization: token ${LS_TOKEN}" -H "Content-Type: application/json" \
      --data-binary "$data" "${REPO_API}${path}")" || { rm -f "$tmp"; fail network "$method $path: curl failed"; }
  else
    code="$(curl -sS ${dump[@]+"${dump[@]}"} -o "$tmp" -w '%{http_code}' -X "$method" \
      -H "Authorization: token ${LS_TOKEN}" "${REPO_API}${path}")" || { rm -f "$tmp"; fail network "$method $path: curl failed"; }
  fi
  if [ "$code" -ge 400 ]; then
    msg="$(jq -r '.message // empty' "$tmp" 2>/dev/null || true)"
    rm -f "$tmp"
    http_fail "$code" "$method $path → HTTP $code${msg:+: $msg}"
  fi
  cat "$tmp"; rm -f "$tmp"
}

# --- Paging ----------------------------------------------------------------
# Forgejo clamps `limit` to the instance's MAX_RESPONSE_ITEMS (50 by default)
# whatever a request asks for, and says so only in a header. One request per list
# verb therefore truncates silently: `limit=200` against a 109-issue tracker
# returns 50 rows and looks complete. Every list endpoint here pages instead.

# Per-process scratch, cleared on exit. Created lazily by the first paged call.
_SCRATCH=""
_PAGED_CALLS=0
_scratch_init() {
  [ -z "$_SCRATCH" ] || return 0
  _SCRATCH="$(mktemp -d)" || die "cannot create temp directory"
  # shellcheck disable=SC2064  # expand $_SCRATCH now: the trap must not depend on later state
  trap "rm -rf '$_SCRATCH'" EXIT
}

# _hdr_value <header-file> <lowercase-name> — the header's value, empty if absent.
# Header names are case-insensitive, the dump is CRLF-terminated, and a redirect
# makes curl append a second block, so the LAST value wins.
_hdr_value() {
  [ -f "$1" ] || return 0
  tr -d '\r' < "$1" | awk -v k="$2" '
    { i = index($0, ":")
      if (i > 0 && tolower(substr($0, 1, i - 1)) == k) { v = substr($0, i + 1); sub(/^[ \t]+/, "", v) } }
    END { if (v != "") print v }'
}

# _hdr_has_next <header-file> — true when the last Link header offers another page.
_hdr_has_next() {
  [ -f "$1" ] || return 1
  tr -d '\r' < "$1" | awk 'tolower($0) ~ /^link:/ { f = ($0 ~ /rel="next"/) } END { exit !f }'
}

# _paged_get PATH QUERY [LIMIT] [ROW_FILTER] — up to LIMIT rows as NDJSON on stdout.
#
# Pages until a page comes back EMPTY, never until a page looks short: a short page
# and a capped one are indistinguishable, which is exactly why the old single-request
# form could not tell "that is all of them" from "that is the first 50".
#
# LIMIT empty means every row. ROW_FILTER is a jq program run over each page array
# (default `.[]`); the rows it emits are what count against LIMIT, so an endpoint
# that mixes resources still yields LIMIT of the ones asked for. When LIMIT is
# reached and the server says more exist, a warning goes to stderr, so a caller can
# finally distinguish a complete list from a clamped one.
#
# Rows accumulate as NDJSON in a file rather than in a jq argument: issue bodies are
# large and an --argjson accumulator would run past the OS argv limit within a page
# or two.
_paged_get() {
  local path="$1" query="$2" limit="${3:-}" filter="${4:-.[]}"
  local page=1 size=100 rows=0 page_out emitted batch count total hdr out
  if [ -n "$limit" ]; then
    case "$limit" in ''|*[!0-9]*) die "--limit must be a positive integer (got '$limit')" ;; esac
    [ "$limit" -gt 0 ] || die "--limit must be a positive integer (got '$limit')"
    [ "$limit" -ge 100 ] || size="$limit"
  fi

  _scratch_init
  _PAGED_CALLS=$((_PAGED_CALLS + 1))
  hdr="$_SCRATCH/headers"; out="$_SCRATCH/rows.$_PAGED_CALLS"
  : >"$out"

  _API_HEADER_FILE="$hdr"
  while :; do
    [ "$page" -le 1000 ] || die "pagination exceeded 1000 pages for $path"
    # `|| exit 1`, not errexit: inside a command substitution (as when a caller caches
    # the rows) set -e is not inherited, and a failed page would read as an empty one.
    batch="$(_api GET "${path}?${query:+$query&}limit=${size}&page=${page}")" || exit 1
    # ONE jq per page (FJ-301): its first line is "<page length> <rows emitted>" and
    # the rows follow, so the page needs no second jq for its length and no wc for the
    # tally. `tojson` prints exactly what `jq -c` would.
    page_out="$(jq -r '. as $p | [$p | '"$filter"'] as $r | "\($p | length) \($r | length)", ($r[] | tojson)' <<<"$batch")" || exit 1
    read -r count emitted <<<"${page_out%%$'\n'*}"
    if [ "$emitted" -gt 0 ]; then printf '%s\n' "${page_out#*$'\n'}" >>"$out"; fi
    rows=$((rows + emitted))
    [ "$count" -gt 0 ] || break
    [ -z "$limit" ] || [ "$rows" -lt "$limit" ] || break
    page=$((page + 1))
  done
  _API_HEADER_FILE=""

  local truncated=false
  total="$(_hdr_value "$hdr" x-total-count)"
  if [ -n "$limit" ] && [ "$rows" -ge "$limit" ]; then
    if [ -n "$total" ] && [ "$total" -gt "$limit" ]; then
      truncated=true
      warn "showing $limit of $total rows for $path; raise --limit to see the rest"
    elif [ -z "$total" ] && _hdr_has_next "$hdr"; then
      truncated=true
      warn "showing $limit rows for $path and more are available; raise --limit to see the rest"
    fi
  fi
  page_meta "$truncated" "$total"

  if [ -n "$limit" ]; then head -n "$limit" "$out"; else cat "$out"; fi
  rm -f "$out"
}

# Labels are fetched once and cached for the life of the process.
_LABELS_CACHE=""
_all_labels() {
  # Not `[ -n … ] || cache=…`: set -e is off on the left of `||`, so a failed fetch
  # (network, 401) used to become an empty label list — "no labels", exit 0. The
  # explicit `|| exit 1` carries the failure (already reported by _api) out.
  if [ -z "$_LABELS_CACHE" ]; then
    _LABELS_CACHE="$(_paged_get "/labels" "" "" | jq -s '.')" || exit 1
  fi
  printf '%s' "$_LABELS_CACHE"
}

# labels_load — fill _LABELS_CACHE in the CALLING process. Every lookup is written
# `$(label_id …)`, a subshell, so a cache filled there dies with it and each lookup
# re-fetched the whole paged label list — once per status role on every set-status
# (FJ-301). Call this at top level before the first lookup; the subshells inherit it.
labels_load() { _all_labels >/dev/null; }

# _status_ids_on_issue <labels-json> <current-ids-json> <keep-name> — the ids of the
# configured status labels the issue carries, except <keep-name>, one per line, in config
# order. One jq for the whole set rather than a label_id plus an `index` test per status
# role (FJ-301). A name resolves to its first id, as label_id does; call labels_load first.
_status_ids_on_issue() {
  printf '%s' "$_LABELS_CACHE" | jq -r --argjson cfg "$1" --argjson cur "$2" --arg keep "$3" '
    (reduce .[] as $l ({}; .[$l.name] //= $l.id)) as $ids
    | $cfg.status // {} | .[] | select(type == "string" and . != $keep)
    | $ids[.] // empty | select(. as $i | $cur | index($i) != null)'
}

# label_id <name> — numeric id on stdout, empty if the label doesn't exist.
label_id() {
  _all_labels | jq -r --arg n "$1" '[.[] | select(.name==$n) | .id] | first // empty'
}
