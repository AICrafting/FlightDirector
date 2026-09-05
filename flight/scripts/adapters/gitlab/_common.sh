#!/usr/bin/env bash
#
# Shared helpers for the GitLab adapter — sourced by issues/pr/ci/labels.
# Consumes the LS_* environment exported by the dispatcher; never reads config.
# shellcheck shell=bash

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

die() { echo "${ADAPTER_NAME:-gitlab}: $*" >&2; exit 1; }

# GitLab auth header applied to every request (personal/project access token).
GL_HEADERS=(-H "PRIVATE-TOKEN: ${LS_TOKEN}")

# _api METHOD PATH [JSON_DATA] — stdout is the response body; exits nonzero on HTTP >= 400.
_api() {
  local method="$1" path="$2" data="${3:-}" tmp code msg
  tmp="$(mktemp)" || die "cannot create temp file"
  if [ -n "$data" ]; then
    code="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" \
      "${GL_HEADERS[@]}" -H "Content-Type: application/json" \
      --data-binary "$data" "${PROJECT_API}${path}")" || { rm -f "$tmp"; die "$method $path: curl failed"; }
  else
    code="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" \
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

# Labels fetched once and cached for the life of the process.
_LABELS_CACHE=""
_all_labels() {
  [ -n "$_LABELS_CACHE" ] || _LABELS_CACHE="$(_api GET "/labels?per_page=100")"
  printf '%s' "$_LABELS_CACHE"
}

# label_id <name> — GitLab numeric id on stdout, empty if the label doesn't exist.
# (GitLab issue label ops use names — like GitHub — so this exists so `labels
# resolve` can return the contract's name⇥id shape and `create` can check existence.)
label_id() {
  _all_labels | jq -r --arg n "$1" '[.[] | select(.name==$n) | .id] | first // empty'
}
