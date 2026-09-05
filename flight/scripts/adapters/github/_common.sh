#!/usr/bin/env bash
#
# Shared helpers for the GitHub adapter — sourced by issues/pr/ci/labels.
# Consumes the LS_* environment exported by the dispatcher; never reads config.
# shellcheck shell=bash

command -v curl >/dev/null 2>&1 || { echo "github adapter: curl is required" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "github adapter: jq is required" >&2; exit 1; }

: "${LS_API:?LS_API not set (dispatcher must export it)}"
: "${LS_OWNER:?LS_OWNER not set}"
: "${LS_REPO:?LS_REPO not set}"
: "${LS_TOKEN:?LS_TOKEN not set — no token resolved for this axis}"

REPO_API="${LS_API%/}/repos/${LS_OWNER}/${LS_REPO}"

die() { echo "${ADAPTER_NAME:-github}: $*" >&2; exit 1; }

# GitHub auth + content headers applied to every request.
GH_HEADERS=(
  -H "Authorization: Bearer ${LS_TOKEN}"
  -H "Accept: application/vnd.github+json"
  -H "X-GitHub-Api-Version: 2022-11-28"
)

# _api METHOD PATH [JSON_DATA] — stdout is the response body; exits nonzero on HTTP >= 400.
# -L follows GitHub's redirects (e.g. log/artifact endpoints). Note: curl drops the
# request body on redirect, so only GET-style paths should rely on -L.
_api() {
  local method="$1" path="$2" data="${3:-}" tmp code msg
  tmp="$(mktemp)" || die "cannot create temp file"
  if [ -n "$data" ]; then
    code="$(curl -sS -L -o "$tmp" -w '%{http_code}' -X "$method" \
      "${GH_HEADERS[@]}" -H "Content-Type: application/json" \
      --data-binary "$data" "${REPO_API}${path}")" || { rm -f "$tmp"; die "$method $path: curl failed"; }
  else
    code="$(curl -sS -L -o "$tmp" -w '%{http_code}' -X "$method" \
      "${GH_HEADERS[@]}" "${REPO_API}${path}")" || { rm -f "$tmp"; die "$method $path: curl failed"; }
  fi
  if [ "$code" -ge 400 ]; then
    msg="$(jq -r '.message // empty' "$tmp" 2>/dev/null || true)"
    rm -f "$tmp"
    die "$method $path → HTTP $code${msg:+: $msg}"
  fi
  cat "$tmp"; rm -f "$tmp"
}

# urlenc <string> — percent-encode for a URL path segment. Label names contain
# spaces and '/', which must be encoded for the DELETE-label-by-name endpoint.
# Handles ASCII (label names are ASCII in this project).
urlenc() {
  local s="$1" out="" c i
  for (( i=0; i<${#s}; i++ )); do
    c="${s:$i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

# Labels fetched once and cached for the life of the process.
_LABELS_CACHE=""
_all_labels() {
  [ -n "$_LABELS_CACHE" ] || _LABELS_CACHE="$(_api GET "/labels?per_page=100")"
  printf '%s' "$_LABELS_CACHE"
}

# label_id <name> — github numeric id on stdout, empty if the label doesn't exist.
# (GitHub label endpoints use names, not ids; this exists so `labels resolve`
# can return the contract's name⇥id shape and `create` can check existence.)
label_id() {
  _all_labels | jq -r --arg n "$1" '[.[] | select(.name==$n) | .id] | first // empty'
}
