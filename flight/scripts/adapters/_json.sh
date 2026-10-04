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

# page_meta TRUNCATED TOTAL [NEXT] — record what a pager knows about the rows it held
# back, for `list --json`. TRUNCATED is true|false; TOTAL is the server's row count, or
# empty when the backend does not report one; NEXT (cursor paging only, #262) is the
# cursor for the following page, or "null" on the last one — when given, the list
# object carries a `next` field. A no-op unless FLIGHT_PAGE_META names a file.
# (Pagers run inside pipelines — subshells — so a file is the only way out.)
page_meta() {
	[ -n "${FLIGHT_PAGE_META:-}" ] || return 0
	jq -cn --argjson t "$1" --arg n "${2:-}" --arg next "${3-}" --argjson paged "$([ $# -ge 3 ] && echo true || echo false)" \
		'{truncated: $t, total: (if $n == "" then null else ($n | tonumber) end)}
		 + (if $paged then {next: (if $next == "null" or $next == "" then null else $next end)} else {} end)' >"$FLIGHT_PAGE_META"
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
	jq -cs --slurpfile m "$1" '{issues: ., truncated: ($m[0].truncated // false), total: ($m[0].total // null)}
		+ (if $m[0] | has("next") then {next: $m[0].next} else {} end)' <<<"$rows"
	rm -f "$1"
}

# ── cursor paging (#262) ──────────────────────────────────────────────────────
# `issues list --json --per-page M [--cursor C]` hands out one page at a time. The
# cursor is opaque to callers: base64 of {v, q, p|t, s, c, n} — the query it belongs
# to (q), where the backend page holding the last row was (p, a page number; or t,
# Jira's nextPageToken), the server page size (s), and the (created, number) key of
# the last row returned (c, n). Rows come newest created first, ties by number
# descending — every backend's own order for these queries — and a later page skips
# any row at or above the last key, so an issue filed between two loads can't repeat a
# row. Page-numbered backends also start one server page back, so an issue that left
# the filter between loads can't make one get skipped. Contract:
# ../../references/json-output.md.

# per_page_arg M — validate --per-page (1..100) and print it.
per_page_arg() {
	case "$1" in ''|*[!0-9]*) fail usage "--per-page must be an integer from 1 to 100 (got '$1')" ;; esac
	[ "$1" -ge 1 ] && [ "$1" -le 100 ] || fail usage "--per-page must be an integer from 1 to 100 (got '$1')"
	printf '%s' "$1"
}

# cursor_decode CURSOR QUERY — the cursor's JSON, or a usage failure when it is not one
# flight issued for exactly this query.
cursor_decode() {
	local raw
	raw="$(jq -rn --arg c "$1" '$c | @base64d' 2>/dev/null)" || raw=""
	jq -e --arg q "$2" 'type == "object" and .v == 1 and .q == $q and (.s | type) == "number" and (.c | type) == "string" and (.n | type) == "number"' \
		<<<"$raw" >/dev/null 2>&1 \
		|| fail usage "--cursor is not a cursor from this list (it was issued for different filters or another tracker, or it is damaged); start again without --cursor"
	printf '%s' "$raw"
}

# cursor_page FETCH FILTER KEY PER_PAGE CURSOR QUERY [TOTAL_HEADER] — one page from a
# page-numbered backend, as NDJSON raw rows on stdout; next/total/truncated go to
# FLIGHT_PAGE_META. FETCH PAGE SIZE prints that server page (a JSON array, headers
# dumped to $_API_HEADER_FILE); FILTER (jq) yields the issue rows of a page; KEY (jq,
# run on a row, with JSON_JQ's utc) yields [created-UTC, number]. TOTAL_HEADER names
# the response header carrying the row total, when the backend sends one.
cursor_page() {
	local fetch="$1" filter="$2" key="$3" per="$4" cursor="$5" query="$6" thdr="${7:-}"
	local cur="" size page last=null tries=0 batch count got=0 take more=false lastkey="" lastpage=0 total="" next=null hdr out rows
	if [ -n "$cursor" ]; then
		cur="$(cursor_decode "$cursor" "$query")" || exit 1
		size="$(jq -r '.s' <<<"$cur")"; page="$(jq -r '.p // 1' <<<"$cur")"
		last="$(jq -c '[.c, .n]' <<<"$cur")"
		[ "$page" -le 1 ] || page=$((page - 1))
	else
		size="$per"; page=1
	fi
	_scratch_init
	_PAGED_CALLS=$((_PAGED_CALLS + 1))
	hdr="$_SCRATCH/headers"; out="$_SCRATCH/rows.$_PAGED_CALLS"; rows="$out.page"
	: >"$out"
	_API_HEADER_FILE="$hdr"
	batch="$("$fetch" "$page" "$size")" || exit 1
	# The page before the cursor's is normally still newer than the last row. If even its
	# newest row is older, rows moved up by more than a page: keep stepping back.
	while [ -n "$cur" ] && [ "$page" -gt 1 ] && [ "$tries" -lt 5 ] \
		&& jq -e --argjson l "$last" "$JSON_JQ"'[('"$filter"')] | length > 0 and ((first | '"$key"') < $l)' <<<"$batch" >/dev/null; do
		page=$((page - 1)); tries=$((tries + 1))
		batch="$("$fetch" "$page" "$size")" || exit 1
	done
	while :; do
		[ "$page" -le 1000 ] || fail backend "pagination exceeded 1000 pages"
		count="$(jq 'length' <<<"$batch")"
		jq -c --argjson l "$last" "$JSON_JQ"'('"$filter"') | select($l == null or (('"$key"') < $l))' <<<"$batch" >"$rows"
		take=$((per - got))
		head -n "$take" "$rows" >>"$out"
		if [ -s "$rows" ]; then
			lastkey="$(head -n "$take" "$rows" | tail -n 1 | jq -c "$JSON_JQ$key")"; lastpage="$page"
		fi
		got="$(wc -l <"$out" | tr -d ' ')"
		if [ "$got" -ge "$per" ]; then
			# More exists when this page holds rows past the last one taken. When the last
			# row taken ended a full server page, look at the next server page rather than
			# guess, so `next` never leads to an empty page.
			if [ "$(wc -l <"$rows" | tr -d ' ')" -gt "$take" ]; then
				more=true
			elif [ "$count" -ge "$size" ]; then
				batch="$("$fetch" "$((page + 1))" "$size")" || exit 1
				jq -e "[$filter] | length > 0" <<<"$batch" >/dev/null && more=true
			fi
			break
		fi
		[ "$count" -ge "$size" ] || break
		page=$((page + 1))
		batch="$("$fetch" "$page" "$size")" || exit 1
	done
	_API_HEADER_FILE=""
	[ -z "$thdr" ] || total="$(_hdr_value "$hdr" "$thdr")"
	if [ "$more" = true ]; then
		next="$(jq -rn --arg q "$query" --argjson p "$lastpage" --argjson s "$size" --argjson k "$lastkey" \
			'{v: 1, q: $q, p: $p, s: $s, c: $k[0], n: $k[1]} | tojson | @base64')"
	fi
	page_meta "$more" "$total" "$next"
	cat "$out"; rm -f "$out" "$rows"
}

# cursor_page_token FETCH FILTER KEY PER_PAGE CURSOR QUERY — cursor_page for a backend
# that pages by an opaque forward-only token (Jira's /search/jql nextPageToken). FETCH
# TOKEN SIZE prints the response object; FILTER yields its rows; `.nextPageToken` names
# the following page. Tokens only move forward, so there is no stepping back: a row can
# be missed when issues leave the filter between loads (reloading from the start
# resyncs). No total is reported.
cursor_page_token() {
	local fetch="$1" filter="$2" key="$3" per="$4" cursor="$5" query="$6"
	local cur="" size token="" last=null resp got=0 take more=false lastkey="" lasttoken="" nexttoken next=null out rows pages=0
	if [ -n "$cursor" ]; then
		cur="$(cursor_decode "$cursor" "$query")" || exit 1
		size="$(jq -r '.s' <<<"$cur")"; token="$(jq -r '.t // ""' <<<"$cur")"
		last="$(jq -c '[.c, .n]' <<<"$cur")"
	else
		size="$per"
	fi
	_scratch_init
	_PAGED_CALLS=$((_PAGED_CALLS + 1))
	out="$_SCRATCH/rows.$_PAGED_CALLS"; rows="$out.page"
	: >"$out"
	while :; do
		pages=$((pages + 1))
		[ "$pages" -le 1000 ] || fail backend "pagination exceeded 1000 pages"
		resp="$("$fetch" "$token" "$size")" || exit 1
		nexttoken="$(jq -r '.nextPageToken // empty' <<<"$resp")"
		jq -c --argjson l "$last" "$JSON_JQ"'('"$filter"') | select($l == null or (('"$key"') < $l))' <<<"$resp" >"$rows"
		take=$((per - got))
		head -n "$take" "$rows" >>"$out"
		if [ -s "$rows" ]; then
			lastkey="$(head -n "$take" "$rows" | tail -n 1 | jq -c "$JSON_JQ$key")"; lasttoken="$token"
		fi
		got="$(wc -l <"$out" | tr -d ' ')"
		if [ "$got" -ge "$per" ]; then
			if [ "$(wc -l <"$rows" | tr -d ' ')" -gt "$take" ] || [ -n "$nexttoken" ]; then more=true; fi
			break
		fi
		[ -n "$nexttoken" ] || break
		token="$nexttoken"
	done
	if [ "$more" = true ]; then
		next="$(jq -rn --arg q "$query" --arg t "$lasttoken" --argjson s "$size" --argjson k "$lastkey" \
			'{v: 1, q: $q, t: (if $t == "" then null else $t end), s: $s, c: $k[0], n: $k[1]} | tojson | @base64')"
	fi
	page_meta "$more" "" "$next"
	cat "$out"; rm -f "$out" "$rows"
}

# dep_emit — one JSON array of {number, title, state} on stdin (FJ-271's dep-list and
# dep-blocking) → one `number⇥title⇥state` row each, or the array unchanged under --json.
dep_emit() {
	if json_mode; then jq -c '.'
	else jq -r '.[] | [.number, .title, .state] | @tsv'
	fi
}
