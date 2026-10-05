#!/usr/bin/env bash
#
# Shared helpers for the GitLab adapter — sourced by issues/pr/ci/labels.
# Consumes the LS_* environment exported by the dispatcher; never reads config.
# shellcheck shell=bash

# Windows shims (jq CRLF, path form); a no-op elsewhere.
# shellcheck source-path=SCRIPTDIR source=../../_portable.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_portable.sh"
# shellcheck source-path=SCRIPTDIR source=../_errors.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_errors.sh"
# shellcheck source-path=SCRIPTDIR source=../_json.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_json.sh"

command -v curl >/dev/null 2>&1 || { echo "gitlab adapter: curl is required" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "gitlab adapter: jq is required" >&2; exit 1; }

require_env LS_API not-configured "LS_API not set (dispatcher must export it)"
require_env LS_OWNER not-configured "LS_OWNER not set"
require_env LS_REPO not-configured "LS_REPO not set"
require_env LS_TOKEN auth "LS_TOKEN not set — no token resolved for this axis"

# GitLab addresses a project by numeric id OR URL-encoded path. owner/repo maps to
# the encoded "group/project" path (all '/' → %2F, incl. subgroups). @uri does that.
PROJECT_ENC="$(urlenc "${LS_OWNER}/${LS_REPO}")"
PROJECT_API="${LS_API%/}/projects/${PROJECT_ENC}"

warn() { echo "${ADAPTER_NAME:-gitlab}: warning: $*" >&2; }

# `urlenc` comes from ../../_portable.sh — every value interpolated into a URL
# goes through it. See the "URL encoding" rule in ../../../references/adapter-contract.md.

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
      --data-binary "$data" "${PROJECT_API}${path}")" || { rm -f "$tmp"; fail network "$method $path: curl failed"; }
  else
    code="$(curl -sS ${dump[@]+"${dump[@]}"} -o "$tmp" -w '%{http_code}' -X "$method" \
      "${GL_HEADERS[@]}" "${PROJECT_API}${path}")" || { rm -f "$tmp"; fail network "$method $path: curl failed"; }
  fi
  if [ "$code" -ge 400 ]; then
    # GitLab errors come as {"message":…} or {"error":…}; message can be an object.
    msg="$(jq -r '(.message // .error // empty) | if type=="string" then . else tojson end' "$tmp" 2>/dev/null || true)"
    rm -f "$tmp"
    http_fail "$code" "$method $path → HTTP $code${msg:+: $msg}"
  fi
  cat "$tmp"; rm -f "$tmp"
}

# _api_try METHOD PATH JSON_DATA OUTFILE — like _api, but an HTTP error is for the caller to
# judge: the status is printed and the body written to OUTFILE. Only curl itself failing
# still stops the adapter. Used where one refusal means "not in this tier" (FJ-271).
_api_try() {
  local method="$1" path="$2" data="$3" out="$4"
  curl -sS -o "$out" -w '%{http_code}' -X "$method" "${GL_HEADERS[@]}" \
    -H "Content-Type: application/json" --data-binary "$data" "${PROJECT_API}${path}" \
    || fail network "$method $path: curl failed"
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
    # `|| exit 1`, not errexit: inside a command substitution (as when a caller caches
    # the rows) set -e is not inherited, and a failed page would read as an empty one.
    batch="$(_api GET "${path}?${query:+$query&}per_page=${size}&page=${page}")" || exit 1
    count="$(printf '%s' "$batch" | jq 'length')"
    printf '%s' "$batch" | jq -c "$filter" >>"$out"
    rows="$(wc -l <"$out" | tr -d ' ')"
    [ "$count" -gt 0 ] || break
    [ -z "$limit" ] || [ "$rows" -lt "$limit" ] || break
    page=$((page + 1))
  done
  _API_HEADER_FILE=""

  # GitLab reports the unclamped total in X-Total (omitted above 10,000 rows).
  local truncated=false
  total="$(_hdr_value "$hdr" x-total)"
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

# Labels fetched once and cached for the life of the process.
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

# label_id <name> — GitLab numeric id on stdout, empty if the label doesn't exist.
# (GitLab issue label ops use names — like GitHub — so this exists so `labels
# resolve` can return the contract's name⇥id shape and `create` can check existence.)
label_id() {
  _all_labels | jq -r --arg n "$1" '[.[] | select(.name==$n) | .id] | first // empty'
}
