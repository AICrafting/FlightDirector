#!/usr/bin/env bash
#
# Shared helpers for the Jira Cloud adapter (REST v3) — sourced by issues/labels.
# Jira is an ISSUES-AXIS-ONLY backend: it implements `issues` + `labels` only.
# `pr`/`ci` keep resolving to the `code` backend (see adapter-contract.md).
# Consumes the LS_* environment exported by the dispatcher; never reads config.
# shellcheck shell=bash

command -v curl >/dev/null 2>&1 || { echo "jira adapter: curl is required" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "jira adapter: jq is required"   >&2; exit 1; }

: "${LS_API:?LS_API not set (dispatcher must export the Jira site base, e.g. https://x.atlassian.net)}"
: "${LS_TOKEN:?LS_TOKEN not set — no Atlassian API token resolved for this axis}"
: "${LS_EMAIL:?LS_EMAIL not set — Jira Basic auth needs the account email (set issues.email in config/secrets)}"
: "${LS_PROJECT:?LS_PROJECT not set — set issues.project (the Jira project key, e.g. KAN) in config}"

SITE="${LS_API%/}"

die() { echo "${ADAPTER_NAME:-jira}: $*" >&2; exit 1; }

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

# --- Minimal ADF shim ------------------------------------------------------
# Jira stores rich text as Atlassian Document Format (ADF) JSON. This is a
# DELIBERATELY minimal converter: paragraphs, fenced code blocks, and bullet/
# ordered lists — enough for issue bodies and comments. Inline marks (bold,
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
      if .type=="code" then
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
