#!/usr/bin/env bash
# Unit tests for the Jira adapter's markdown <-> ADF shim (FJ-178): md_to_adf and
# adf_to_text in flight/scripts/adapters/jira/_common.sh. They are pure jq over
# stdin/stdout, so this exercises them directly — no network, no credentials.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMON="$REPO_ROOT/flight/scripts/adapters/jira/_common.sh"

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail+1)); fi; }
section() { printf '\033[1m── %s ──\033[0m\n' "$1"; }

# Source the shim in a throwaway shell (it expects adapter env) and lift ADF_JQ out.
ADF_JQ="$(LS_API=x LS_PROJECT=x LS_TOKEN=x LS_EMAIL=x bash -c '. "$1" >/dev/null 2>&1; printf "%s" "$ADF_JQ"' _ "$COMMON")"
if [ -z "${ADF_JQ:-}" ]; then
	check "jira shim sourced" 0 "ADF_JQ not defined"
	printf '\n\033[0;31mPassed: %d  Failed: %d\033[0m\n' "$pass" "$fail"
	exit 1
fi

to_adf()  { jq -Rsc "$ADF_JQ"'md_to_adf'; }   # markdown on stdin -> ADF doc JSON
to_text() { jq -r "$ADF_JQ"'adf_to_text'; }   # ADF doc JSON on stdin -> text
heading_doc() { # $1 level, $2 text -> an ADF doc holding one heading, as Jira's editor stores it
	jq -nc --argjson l "$1" --arg t "$2" \
		'{type:"doc",version:1,content:[{type:"heading",attrs:{level:$l},content:[{type:"text",text:$t}]}]}'
}

section "read path: ADF headings keep their level"
for level in 1 2 3; do
	hashes="$(printf '%*s' "$level" '' | tr ' ' '#')"
	got="$(heading_doc "$level" "Acceptance" | to_text)"
	check "a level-$level heading reads back as '$hashes Acceptance'" \
		"$([ "$got" = "$hashes Acceptance" ] && echo 1 || echo 0)" "got: $got"
done
got="$(jq -nc '{type:"doc",version:1,content:[{type:"heading",content:[{type:"text",text:"No level"}]}]}' | to_text)"
check "a heading with no attrs.level reads as level 1" "$([ "$got" = "# No level" ] && echo 1 || echo 0)" "got: $got"
got="$(jq -nc '{type:"doc",version:1,content:[
		{type:"heading",attrs:{level:2},content:[{type:"text",text:"Acceptance"}]},
		{type:"paragraph",content:[{type:"text",text:"it works"}]}]}' | to_text)"
check "a heading followed by a paragraph stays a separate block" \
	"$([ "$got" = $'## Acceptance\n\nit works' ] && echo 1 || echo 0)" "got: $got"

section "write path: a leading # line becomes an ADF heading"
for level in 1 2 3 6; do
	hashes="$(printf '%*s' "$level" '' | tr ' ' '#')"
	adf="$(printf '%s Test plans\n' "$hashes" | to_adf)"
	check "'$hashes Test plans' becomes a level-$level heading node" \
		"$(jq -e --argjson l "$level" '.content == [{type:"heading",attrs:{level:$l},content:[{type:"text",text:"Test plans"}]}]' <<<"$adf" >/dev/null && echo 1 || echo 0)" "$adf"
done
adf="$(printf '####### seven\n' | to_adf)"
check "seven #s is not a heading (markdown stops at six)" \
	"$(jq -e '.content[0].type == "paragraph"' <<<"$adf" >/dev/null && echo 1 || echo 0)" "$adf"
adf="$(printf 'intro line\n## Acceptance\n- one\n' | to_adf)"
check "a heading ends the paragraph above it and starts its own block" \
	"$(jq -e '[.content[].type] == ["paragraph","heading","bulletList"]' <<<"$adf" >/dev/null && echo 1 || echo 0)" "$adf"
adf="$(printf '## Summary   \n' | to_adf)"
check "trailing whitespace is trimmed from the heading text" \
	"$(jq -e '.content[0].content[0].text == "Summary"' <<<"$adf" >/dev/null && echo 1 || echo 0)" "$adf"

section "round trip: md_to_adf then adf_to_text preserves the section anchors"
# (A blank line follows the --- because every ADF block is joined with one on read.)
body=$'## Summary\n\nWhat changed.\n\n## Acceptance\n\n- [ ] it round-trips\n- [ ] tests exist\n\n## Test plans\n\n1. run it\n\n```\n## not a heading, just code\n```\n\n---\n\nsigned'
back="$(printf '%s' "$body" | to_adf | to_text)"
check "the body comes back unchanged" "$([ "$back" = "$body" ] && echo 1 || echo 0)" "got: $back"
for anchor in '## Summary' '## Acceptance' '## Test plans'; do
	check "'$anchor' survives as its own line" "$(grep -qx -- "$anchor" <<<"$back" && echo 1 || echo 0)" "got: $back"
done
adf="$(printf '%s' "$body" | to_adf)"
check "a '##' inside a fenced code block is not turned into a heading" \
	"$(jq -e '[.content[] | select(.type=="heading")] | length == 3' <<<"$adf" >/dev/null && echo 1 || echo 0)" "$adf"

section "regression: paragraphs, code blocks, lists and rules convert as before"
md=$'para one\nline two\n\n#hashtag, not a heading\n\n```\n# a shell comment\nx\n```\n\n- a\n- b\n\n1. one\n2. two\n\n---\ntail\n'
# The ADF this markdown produced before FJ-178 — any drift here is a behaviour change.
want='{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"para one\nline two"}]},{"type":"paragraph","content":[{"type":"text","text":"#hashtag, not a heading"}]},{"type":"codeBlock","content":[{"type":"text","text":"# a shell comment\nx"}]},{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"a"}]}]},{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"b"}]}]}]},{"type":"orderedList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"one"}]}]},{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"two"}]}]}]},{"type":"rule"},{"type":"paragraph","content":[{"type":"text","text":"tail"}]}]}'
adf="$(printf '%s' "$md" | to_adf)"
check "md_to_adf output is unchanged for non-heading markdown" \
	"$(jq -e --argjson w "$want" '. == $w' <<<"$adf" >/dev/null && echo 1 || echo 0)" "$adf"
check "a '#' with no space after it stays paragraph text" \
	"$(jq -e '.content[1] == {type:"paragraph",content:[{type:"text",text:"#hashtag, not a heading"}]}' <<<"$adf" >/dev/null && echo 1 || echo 0)" "$adf"
check "a '#' line inside a fenced code block stays code" \
	"$(jq -e '.content[2].type == "codeBlock" and (.content[2].content[0].text | startswith("# a shell comment"))' <<<"$adf" >/dev/null && echo 1 || echo 0)" "$adf"
back="$(to_text <<<"$adf")"
want_text=$'para one\nline two\n\n#hashtag, not a heading\n\n```\n# a shell comment\nx\n```\n\n- a\n- b\n\n1. one\n1. two\n\n---\n\ntail'
check "adf_to_text output is unchanged for non-heading blocks" \
	"$([ "$back" = "$want_text" ] && echo 1 || echo 0)" "got: $back"
got="$(printf '"plain string body"' | to_text)"
check "a plain-string body passes through adf_to_text untouched" \
	"$([ "$got" = "plain string body" ] && echo 1 || echo 0)" "got: $got"

# Summary: plain when nothing failed, red when something did (#123).
[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
