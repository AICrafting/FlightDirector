#!/usr/bin/env bash
#
# Shared helpers for the Jira Cloud adapter (REST v3) — sourced by issues/labels.
# Jira is an ISSUES-AXIS-ONLY backend: it implements `issues` + `labels` only.
# `pr`/`ci` keep resolving to the `code` backend (see adapter-contract.md).
# Consumes the LS_* environment exported by the dispatcher; never reads config.
# shellcheck shell=bash

# Windows shims (jq CRLF, path form); a no-op elsewhere.
# shellcheck source-path=SCRIPTDIR source=../../_portable.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_portable.sh"

command -v curl >/dev/null 2>&1 || { echo "jira adapter: curl is required" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "jira adapter: jq is required"   >&2; exit 1; }

: "${LS_API:?LS_API not set (dispatcher must export the Jira site base, e.g. https://x.atlassian.net)}"
: "${LS_TOKEN:?LS_TOKEN not set — no Atlassian API token resolved for this axis}"
: "${LS_EMAIL:?LS_EMAIL not set — Jira Basic auth needs the account email (set issues.email in config/secrets)}"
: "${LS_PROJECT:?LS_PROJECT not set — set issues.project (the Jira project key, e.g. KAN) in config}"

SITE="${LS_API%/}"

die()  { echo "${ADAPTER_NAME:-jira}: $*" >&2; exit 1; }
warn() { echo "${ADAPTER_NAME:-jira}: warning: $*" >&2; }

# HTTP Basic auth: email:api_token (classic Atlassian API token, NOT OAuth).
JIRA_AUTH=(-u "${LS_EMAIL}:${LS_TOKEN}")

# _api METHOD PATH [JSON_DATA] — PATH is relative to the site root (starts with
# /rest/api/3/…). stdout is the response body; exits nonzero on HTTP >= 400.
_api() {
  local method="$1" path="$2" data="${3:-}" tmp code msg
  tmp="$(mktemp)" || die "cannot create temp file"
  if [ -n "$data" ]; then
    code="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" \
      "${JIRA_AUTH[@]}" -H "Accept: application/json" -H "Content-Type: application/json" \
      --data-binary "$data" "${SITE}${path}")" || { rm -f "$tmp"; die "$method $path: curl failed"; }
  else
    code="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" \
      "${JIRA_AUTH[@]}" -H "Accept: application/json" "${SITE}${path}")" || { rm -f "$tmp"; die "$method $path: curl failed"; }
  fi
  if [ "$code" -ge 400 ]; then
    msg="$(jq -r '((.errorMessages // []) | join("; ")) as $m
                  | (if $m == "" then ((.errors // {}) | to_entries | map("\(.key): \(.value)") | join("; ")) else $m end)' \
          "$tmp" 2>/dev/null || true)"
    rm -f "$tmp"
    die "$method $path → HTTP $code${msg:+: $msg}"
  fi
  cat "$tmp"; rm -f "$tmp"
}

# --- Paging ----------------------------------------------------------------
# Jira clamps `maxResults` to its own ceiling and reports the clamp in the payload,
# so a single request per list verb truncates silently. Jira's two read paths cannot
# share one loop: the enhanced-JQL search pages with an opaque `nextPageToken`, while
# the older collection endpoints page with a numeric `startAt`. Both stop only when
# the response says there is no more, never because a page looked short.

# Per-process scratch, cleared on exit. Created lazily by the first paged call.
_SCRATCH=""
_PAGED_CALLS=0
_scratch_init() {
  [ -z "$_SCRATCH" ] || return 0
  _SCRATCH="$(mktemp -d)" || die "cannot create temp directory"
  # shellcheck disable=SC2064  # expand $_SCRATCH now: the trap must not depend on later state
  trap "rm -rf '$_SCRATCH'" EXIT
}

# _paged_rows <limit> — trim the accumulated NDJSON to LIMIT rows and emit it.
_paged_rows() {
  if [ -n "$1" ]; then head -n "$1" "$2"; else cat "$2"; fi
  rm -f "$2"
}

# _paged_size <limit> — rows to ask for per request: the limit, capped at 100.
_paged_size() {
  [ -n "$1" ] || { printf '100'; return 0; }
  case "$1" in ''|*[!0-9]*) die "--limit must be a positive integer (got '$1')" ;; esac
  [ "$1" -gt 0 ] || die "--limit must be a positive integer (got '$1')"
  if [ "$1" -ge 100 ]; then printf '100'; else printf '%s' "$1"; fi
}

# _jql_search <jql> <fields-json> [LIMIT] — up to LIMIT issues as NDJSON.
# /search/jql reports no total, so a capped result can only be announced as
# "more are available".
_jql_search() {
  local jql="$1" fields="$2" limit="${3:-}"
  local size token="" payload resp rows=0 page=0 out
  size="$(_paged_size "$limit")"
  _scratch_init
  _PAGED_CALLS=$((_PAGED_CALLS + 1))
  out="$_SCRATCH/rows.$_PAGED_CALLS"
  : >"$out"
  while :; do
    page=$((page + 1))
    [ "$page" -le 1000 ] || die "pagination exceeded 1000 pages for /search/jql"
    payload="$(jq -n --arg j "$jql" --argjson m "$size" --argjson f "$fields" --arg t "$token" \
      '{jql:$j, maxResults:$m, fields:$f} + (if $t == "" then {} else {nextPageToken:$t} end)')"
    resp="$(_api POST "/rest/api/3/search/jql" "$payload")"
    printf '%s' "$resp" | jq -c '.issues[]?' >>"$out"
    rows="$(wc -l <"$out" | tr -d ' ')"
    token="$(printf '%s' "$resp" | jq -r '.nextPageToken // empty')"
    [ -n "$token" ] || break
    [ -z "$limit" ] || [ "$rows" -lt "$limit" ] || break
  done
  if [ -n "$limit" ] && [ "$rows" -ge "$limit" ] && [ -n "$token" ]; then
    warn "showing $limit rows for /search/jql and more are available; raise --limit to see the rest"
  fi
  _paged_rows "$limit" "$out"
}

# _offset_get <path> <query> <array-key> [LIMIT] — up to LIMIT rows as NDJSON from a
# startAt-paged collection endpoint (/label, /issue/KEY/comment). These do report a
# `total`, so a capped result can name the number it is hiding.
_offset_get() {
  local path="$1" query="$2" key="$3" limit="${4:-}"
  local size start=0 resp batch rows=0 page=0 total="" out
  size="$(_paged_size "$limit")"
  _scratch_init
  _PAGED_CALLS=$((_PAGED_CALLS + 1))
  out="$_SCRATCH/rows.$_PAGED_CALLS"
  : >"$out"
  while :; do
    page=$((page + 1))
    [ "$page" -le 1000 ] || die "pagination exceeded 1000 pages for $path"
    resp="$(_api GET "${path}?${query:+$query&}startAt=${start}&maxResults=${size}")"
    batch="$(printf '%s' "$resp" | jq --arg k "$key" '(.[$k] // []) | length')"
    printf '%s' "$resp" | jq -c --arg k "$key" '(.[$k] // [])[]' >>"$out"
    rows="$(wc -l <"$out" | tr -d ' ')"
    total="$(printf '%s' "$resp" | jq -r '.total // empty')"
    [ "$batch" -gt 0 ] || break
    # Jira clamps maxResults to its own ceiling, so advance by what it actually sent.
    start=$((start + batch))
    [ -z "$total" ] || [ "$start" -lt "$total" ] || break
    [ -z "$limit" ] || [ "$rows" -lt "$limit" ] || break
  done
  if [ -n "$limit" ] && [ "$rows" -ge "$limit" ] && [ -n "$total" ] && [ "$total" -gt "$limit" ]; then
    warn "showing $limit of $total rows for $path; raise --limit to see the rest"
  fi
  _paged_rows "$limit" "$out"
}

# --- Minimal ADF shim ------------------------------------------------------
# Jira stores rich text as Atlassian Document Format (ADF) JSON. This is a
# DELIBERATELY minimal converter: paragraphs, fenced code blocks, bullet/
# ordered lists, and a `---` rule (the dispatcher's signature separator) — enough for issue bodies and comments. Inline marks (bold,
# links, …) are carried as plain text, not styled. See adapter-contract.md.
#
# ADF_JQ is prepended to jq programs that need md_to_adf / adf_to_text.
#   md_to_adf : input is a raw markdown string  -> ADF doc object
#   adf_to_text: input is an ADF doc object      -> plain-text string
# shellcheck disable=SC2016  # this is a jq program; $-vars are jq's, not the shell's
ADF_JQ='
def md_to_adf:
  def flush:
    if   .mode=="para"    then .blocks += [{type:"para",    text:(.buf|join("\n"))}]
    elif .mode=="code"    then .blocks += [{type:"code",    text:(.buf|join("\n"))}]
    elif .mode=="bullet"  then .blocks += [{type:"bullet",  items:.buf}]
    elif .mode=="ordered" then .blocks += [{type:"ordered", items:.buf}]
    else . end
    | .mode="none" | .buf=[];
  (gsub("\r";"") | split("\n")) as $lines
  | (reduce $lines[] as $l ({blocks:[], mode:"none", buf:[]};
        if .mode=="code" then
          (if ($l|test("^```")) then (.blocks += [{type:"code", text:(.buf|join("\n"))}] | .mode="none" | .buf=[])
           else .buf += [$l] end)
        elif ($l|test("^```")) then (flush | .mode="code" | .buf=[])
        elif ($l|test("^[[:space:]]*$")) then flush
        elif ($l|test("^[[:space:]]*-{3,}[[:space:]]*$")) then (flush | .blocks += [{type:"rule"}])
        elif ($l|test("^[[:space:]]*[-*][[:space:]]+")) then
          (if .mode=="bullet" then . else flush end)
          | .mode="bullet" | .buf += [($l|sub("^[[:space:]]*[-*][[:space:]]+";""))]
        elif ($l|test("^[[:space:]]*[0-9]+[.)][[:space:]]+")) then
          (if .mode=="ordered" then . else flush end)
          | .mode="ordered" | .buf += [($l|sub("^[[:space:]]*[0-9]+[.)][[:space:]]+";""))]
        else
          (if .mode=="para" then . else flush end)
          | .mode="para" | .buf += [$l]
        end
     ) | flush | .blocks) as $blocks
  | {type:"doc", version:1, content: [
      $blocks[] |
      if .type=="rule" then {type:"rule"}
      elif .type=="code" then
        {type:"codeBlock", content: (if .text=="" then [] else [{type:"text", text:.text}] end)}
      elif .type=="bullet" then
        {type:"bulletList", content: [.items[] | {type:"listItem", content:[{type:"paragraph", content:[{type:"text", text:.}]}]}]}
      elif .type=="ordered" then
        {type:"orderedList", content: [.items[] | {type:"listItem", content:[{type:"paragraph", content:[{type:"text", text:.}]}]}]}
      else
        {type:"paragraph", content: (if .text=="" then [] else [{type:"text", text:.text}] end)}
      end
    ]};

def adf_to_text:
  def inline: [.. | .text? // empty] | join("");
  if type=="object" and (.type=="doc") then
    ([.content[]? |
        if   .type=="paragraph"  then inline
        elif .type=="heading"    then inline
        elif .type=="codeBlock"  then "```\n" + inline + "\n```"
        elif .type=="rule"       then "---"
        elif .type=="bulletList" then ([.content[]? | "- " + inline]  | join("\n"))
        elif .type=="orderedList" then ([.content[]? | "1. " + inline] | join("\n"))
        else inline end
     ] | join("\n\n"))
  elif type=="string" then .
  else ([.. | .text? // empty] | join("")) end;
'

# md_to_adf_json <string> — emit the ADF doc JSON for a markdown string.
md_to_adf_json() { printf '%s' "$1" | jq -R -s "$ADF_JQ"' md_to_adf '; }
# md_file_to_adf_json <path> — same, from a file.
md_file_to_adf_json() { jq -R -s "$ADF_JQ"' md_to_adf ' < "$1"; }
