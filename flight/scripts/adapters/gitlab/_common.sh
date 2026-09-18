#!/usr/bin/env bash
#
# Shared helpers for the GitLab adapter — sourced by issues/pr/ci/labels.
# Consumes the LS_* environment exported by the dispatcher; never reads config.
# shellcheck shell=bash

# Windows shims (jq CRLF, path form); a no-op elsewhere.
# shellcheck source-path=SCRIPTDIR source=../../_portable.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_portable.sh"

command -v curl >/dev/null 2>&1 || { echo "gitlab adapter: curl is required" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "gitlab adapter: jq is required" >&2; exit 1; }

: "${LS_API:?LS_API not set (dispatcher must export it)}"
: "${LS_OWNER:?LS_OWNER not set}"
: "${LS_REPO:?LS_REPO not set}"
: "${LS_TOKEN:?LS_TOKEN not set — no token resolved for this axis}"

# GitLab addresses a project by numeric id OR URL-encoded path. owner/repo maps to
# the encoded "group/project" path (all '/' → %2F, incl. subgroups). @uri does that.
PROJECT_ENC="$(printf '%s' "${LS_OWNER}/${LS_REPO}" | jq -sRr @uri)"
PROJECT_API="${LS_API%/}/projects/${PROJECT_ENC}"

die()  { echo "${ADAPTER_NAME:-gitlab}: $*" >&2; exit 1; }
warn() { echo "${ADAPTER_NAME:-gitlab}: warning: $*" >&2; }

# Percent-encode one URL path segment. Label names commonly contain '/'.
urlenc() { printf '%s' "$1" | jq -sRr @uri; }

# GitLab auth header applied to every request (personal/project access token).
GL_HEADERS=(-H "PRIVATE-TOKEN: ${LS_TOKEN}")

# _api METHOD PATH [JSON_DATA] — stdout is the response body; exits nonzero on HTTP >= 400.
# When _API_HEADER_FILE names a file, the response headers are dumped there as well
# (that is how _paged_get reads X-Total). The flag is omitted when it is unset, so an
# ordinary call remains the plain curl it always was.
_api() {
  local method="$1" path="$2" data="${3:-}" tmp code msg
  local dump=()
  [ -z "${_API_HEADER_FILE:-}" ] || dump=(-D "$_API_HEADER_FILE")
  tmp="$(mktemp)" || die "cannot create temp file"
  if [ -n "$data" ]; then
    code="$(curl -sS ${dump[@]+"${dump[@]}"} -o "$tmp" -w '%{http_code}' -X "$method" \
      "${GL_HEADERS[@]}" -H "Content-Type: application/json" \
      --data-binary "$data" "${PROJECT_API}${path}")" || { rm -f "$tmp"; die "$method $path: curl failed"; }
  else
    code="$(curl -sS ${dump[@]+"${dump[@]}"} -o "$tmp" -w '%{http_code}' -X "$method" \
      "${GL_HEADERS[@]}" "${PROJECT_API}${path}")" || { rm -f "$tmp"; die "$method $path: curl failed"; }
  fi
  if [ "$code" -ge 400 ]; then
    # GitLab errors come as {"message":…} or {"error":…}; message can be an object.
    msg="$(jq -r '(.message // .error // empty) | if type=="string" then . else tojson end' "$tmp" 2>/dev/null || true)"
    rm -f "$tmp"
    die "$method $path → HTTP $code${msg:+: $msg}"
  fi
  cat "$tmp"; rm -f "$tmp"
}

# --- Paging ----------------------------------------------------------------
# GitLab caps `per_page` at 100, so one request per list verb truncates silently on
# any project past that. Every list endpoint here pages instead.

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
  local page=1 size=100 rows=0 batch count total hdr out
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
    batch="$(_api GET "${path}?${query:+$query&}per_page=${size}&page=${page}")"
    count="$(printf '%s' "$batch" | jq 'length')"
    printf '%s' "$batch" | jq -c "$filter" >>"$out"
    rows="$(wc -l <"$out" | tr -d ' ')"
    [ "$count" -gt 0 ] || break
    [ -z "$limit" ] || [ "$rows" -lt "$limit" ] || break
    page=$((page + 1))
  done
  _API_HEADER_FILE=""

  if [ -n "$limit" ] && [ "$rows" -ge "$limit" ]; then
    # GitLab reports the unclamped total in X-Total.
    total="$(_hdr_value "$hdr" x-total)"
    if [ -n "$total" ] && [ "$total" -gt "$limit" ]; then
      warn "showing $limit of $total rows for $path; raise --limit to see the rest"
    elif [ -z "$total" ] && _hdr_has_next "$hdr"; then
      warn "showing $limit rows for $path and more are available; raise --limit to see the rest"
    fi
  fi

  if [ -n "$limit" ]; then head -n "$limit" "$out"; else cat "$out"; fi
  rm -f "$out"
}

# Labels fetched once and cached for the life of the process.
_LABELS_CACHE=""
_all_labels() {
  [ -n "$_LABELS_CACHE" ] || _LABELS_CACHE="$(_paged_get "/labels" "" "" | jq -s '.')"
  printf '%s' "$_LABELS_CACHE"
}

# label_id <name> — GitLab numeric id on stdout, empty if the label doesn't exist.
# (GitLab issue label ops use names — like GitHub — so this exists so `labels
# resolve` can return the contract's name⇥id shape and `create` can check existence.)
label_id() {
  _all_labels | jq -r --arg n "$1" '[.[] | select(.name==$n) | .id] | first // empty'
}
