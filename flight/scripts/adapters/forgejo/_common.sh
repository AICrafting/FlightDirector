#!/usr/bin/env bash
#
# Shared helpers for the Forgejo adapter — sourced by issues/pr/ci/labels.
# Consumes the LS_* environment exported by the dispatcher; never reads config.
# shellcheck shell=bash

command -v curl >/dev/null 2>&1 || { echo "forgejo adapter: curl is required" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "forgejo adapter: jq is required" >&2; exit 1; }

: "${LS_API:?LS_API not set (dispatcher must export it)}"
: "${LS_OWNER:?LS_OWNER not set}"
: "${LS_REPO:?LS_REPO not set}"
: "${LS_TOKEN:?LS_TOKEN not set — no token resolved for this axis}"

REPO_API="${LS_API%/}/repos/${LS_OWNER}/${LS_REPO}"

die() { echo "${ADAPTER_NAME:-forgejo}: $*" >&2; exit 1; }

# _api METHOD PATH [JSON_DATA] — stdout is the response body; exits nonzero on HTTP >= 400.
_api() {
  local method="$1" path="$2" data="${3:-}" tmp code msg
  tmp="$(mktemp)"
  if [ -n "$data" ]; then
    code="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" \
      -H "Authorization: token ${LS_TOKEN}" -H "Content-Type: application/json" \
      --data-binary "$data" "${REPO_API}${path}")" || { rm -f "$tmp"; die "$method $path: curl failed"; }
  else
    code="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" \
      -H "Authorization: token ${LS_TOKEN}" "${REPO_API}${path}")" || { rm -f "$tmp"; die "$method $path: curl failed"; }
  fi
  if [ "$code" -ge 400 ]; then
    msg="$(jq -r '.message // empty' "$tmp" 2>/dev/null || true)"
    rm -f "$tmp"
    die "$method $path → HTTP $code${msg:+: $msg}"
  fi
  cat "$tmp"; rm -f "$tmp"
}

# Labels are fetched once and cached for the life of the process.
_LABELS_CACHE=""
_all_labels() {
  local page batch count
  if [ -z "$_LABELS_CACHE" ]; then
    _LABELS_CACHE='[]'
    page=1
    while :; do
      [ "$page" -le 1000 ] || die "labels pagination exceeded 1000 pages"
      batch="$(_api GET "/labels?limit=100&page=$page")"
      _LABELS_CACHE="$(jq -cn --argjson accumulated "$_LABELS_CACHE" --argjson batch "$batch" '$accumulated + $batch')"
      count="$(printf '%s' "$batch" | jq 'length')"
      [ "$count" -gt 0 ] || break
      page=$((page + 1))
    done
  fi
  printf '%s' "$_LABELS_CACHE"
}

# label_id <name> — numeric id on stdout, empty if the label doesn't exist.
label_id() {
  _all_labels | jq -r --arg n "$1" '[.[] | select(.name==$n) | .id] | first // empty'
}
