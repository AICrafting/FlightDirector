#!/usr/bin/env bash
#
# Shared helpers for the adapters' `--json` forms (#253) — sourced by each _common.sh.
# shellcheck shell=bash
#
# Under `--json` the dispatcher exports LS_JSON=1 and an adapter's issue verbs emit
# BASE objects: the backend's fields mapped onto one shape, identical on every
# backend. The dispatcher finishes them (status role, signature split, tracker
# identity — the parts only it knows) with ../issue-json.jq. Shapes:
# ../../references/json-output.md.

# json_mode — true when the dispatcher asked for JSON.
json_mode() { [ "${LS_JSON:-}" = 1 ]; }

# JSON_JQ is prepended to jq programs that build base objects.
#   utc: an ISO-8601 timestamp with any offset (Z, +00:00, +0000, -04:00, with or
#        without fractional seconds) → "YYYY-MM-DDTHH:MM:SSZ"; null stays null; a
#        value it cannot read is passed through unchanged rather than dropped.
# shellcheck disable=SC2016,SC2034  # a jq program for the sourcing adapters; $-vars are jq's
JSON_JQ='
def utc:
  if type != "string" then null
  else ([capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<f>[.][0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")] | first) as $m
  | if $m == null then .
    else (($m.d + "Z") | fromdateiso8601) as $t
    | (($m.z // "Z") | if . == "Z" then 0
        else (.[0:1]) as $s | (.[1:] | gsub(":"; "")) as $hm
        | (($hm[0:2] | tonumber) * 3600 + ($hm[2:4] | tonumber) * 60) * (if $s == "+" then 1 else -1 end)
        end) as $off
    | ($t - $off) | todate
    end
  end;
#   base_label: a label object (name, color, description) → the shared shape; the
#        colour as "#rrggbb" lowercase whether the backend sends "#" or not, an
#        empty description as null. Jira labels are bare strings with neither.
def base_label:
  if type == "string" then {name: ., color: null, description: null}
  else {
    name: .name,
    color: (.color | if type == "string" and length > 0 then "#" + (ltrimstr("#") | ascii_downcase) else null end),
    description: (.description | if type == "string" and length > 0 then . else null end)
  } end;
'

# page_meta TRUNCATED TOTAL — record what a pager knows about the rows it held back,
# for `list --json`. TRUNCATED is true|false; TOTAL is the server's row count, or
# empty when the backend does not report one. A no-op unless FLIGHT_PAGE_META names
# a file. (Pagers run inside pipelines — subshells — so a file is the only way out.)
page_meta() {
	[ -n "${FLIGHT_PAGE_META:-}" ] || return 0
	jq -cn --argjson t "$1" --arg n "${2:-}" \
		'{truncated: $t, total: (if $n == "" then null else ($n | tonumber) end)}' >"$FLIGHT_PAGE_META"
}

# page_meta_init — a fresh meta file (pessimistic default: nothing known) on stdout.
page_meta_init() {
	local f
	f="$(mktemp)" || fail backend "cannot create a temp file"
	printf '{"truncated":false,"total":null}\n' >"$f"
	printf '%s' "$f"
}

# emit_list META_FILE — stdin: NDJSON base issues. stdout: one list object.
# Reads stdin to EOF before opening META_FILE: the pager upstream writes the meta
# before its last row, and EOF arrives only once every writer has exited.
emit_list() {
	local rows
	rows="$(cat)"
	jq -cs --slurpfile m "$1" '{issues: ., truncated: ($m[0].truncated // false), total: ($m[0].total // null)}' <<<"$rows"
	rm -f "$1"
}
