#!/usr/bin/env bash
# Internal named-tracker selector/resolver. The dispatcher validates the config
# before invoking this helper; this script never reads secrets or calls adapters.
set -euo pipefail

die() { echo "flight: $*" >&2; exit 1; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

[ $# -ge 2 ] || die "tracker-config: usage: tracker-config.sh <select|resolve> --config FILE [args]"
command="$1"; shift
[ "${1:-}" = --config ] && [ $# -ge 2 ] || die "tracker-config: --config FILE required"
config="$2"; shift 2
[ -f "$config" ] || die "tracker-config: config '$config' not found"

selector=""; number=""
while [ $# -gt 0 ]; do
	case "$1" in
		--tracker) [ $# -ge 2 ] || die "--tracker needs a reference"; selector="$2"; shift 2 ;;
		--number) [ $# -ge 2 ] || die "--number needs an issue identifier"; number="$2"; shift 2 ;;
		*) die "tracker-config: unknown arg '$1'" ;;
	esac
done

select_json() {
	if [ -n "$selector" ]; then
		jq -ce --arg s "$(lower "$selector")" '
			[.issueTrackers[] | select(
				(.ref | ascii_downcase) == $s
				or any((.aliases // [])[]; ascii_downcase == $s)
			)] | if length == 1 then .[0] else empty end
		' "$config" || die "unknown tracker '$selector'; choose a configured ref or alias"
	else
		jq -ce '[.issueTrackers[] | select(.default == true)] | if length == 1 then .[0] else empty end' "$config" \
			|| die "issueTrackers must contain exactly one default"
	fi
}

if [ "$command" = select ]; then
	select_json
	exit 0
fi
[ "$command" = resolve ] || die "tracker-config: unknown command '$command'"
[ -n "$number" ] || die "issues resolve: --number required"

raw="$number"
raw_l="$(lower "$raw")"
candidate_refs=(); candidate_numbers=(); candidate_json=()

# One candidate per tracker, even when both its ref and an alias match.
while IFS=$'\x1f' read -r ref backend project aliases tracker_json; do
	[ -n "$ref" ] || continue
	tokens="$ref"
	[ -z "$aliases" ] || tokens="$tokens,$aliases"
	if [ "$backend" = jira ] && [ -n "$project" ]; then tokens="$tokens,$project"; fi
	old_ifs="$IFS"; IFS=,
	for token in $tokens; do
		IFS="$old_ifs"
		token_l="$(lower "$token")"
		native=""
		if [ "$backend" = jira ]; then
			if [[ "$raw_l" =~ ^${token_l}[-#]?([0-9]+)$ ]]; then
				[ -n "$project" ] || project="$ref"
				native="$(printf '%s' "$project" | tr '[:lower:]' '[:upper:]')-${BASH_REMATCH[1]}"
			fi
		elif [[ "$raw_l" =~ ^${token_l}[-#]?([0-9]+)$ ]]; then
			native="${BASH_REMATCH[1]}"
		fi
		if [ -n "$native" ]; then
			seen=0
			for existing in "${candidate_refs[@]+"${candidate_refs[@]}"}"; do [ "$existing" = "$ref" ] && seen=1; done
			if [ "$seen" = 0 ]; then
				candidate_refs+=("$ref"); candidate_numbers+=("$native"); candidate_json+=("$tracker_json")
			fi
		fi
	done
	IFS="$old_ifs"
done < <(jq -cr '.issueTrackers[] | [
	.ref,
	(.backend | ascii_downcase),
	(.project // ""),
	((.aliases // []) | join(",")),
	(tojson)
] | join("\u001f")' "$config")

selected=""; native=""; tracker=""
if [ ${#candidate_refs[@]} -gt 1 ]; then
	list="$(printf '%s, ' "${candidate_refs[@]}")"; list="${list%, }"
	die "ambiguous issue '$number'; candidate trackers: $list"
fi
if [ -n "$selector" ]; then
	tracker="$(select_json)"
	selected="$(printf '%s' "$tracker" | jq -r '.ref')"
	if [ ${#candidate_refs[@]} -gt 0 ]; then
		for i in "${!candidate_refs[@]}"; do
			if [ "${candidate_refs[$i]}" = "$selected" ]; then native="${candidate_numbers[$i]}"; fi
		done
		[ -n "$native" ] || die "tracker selector '$selector' conflicts with qualified issue '$number'"
	else
		backend="$(printf '%s' "$tracker" | jq -r '.backend | ascii_downcase')"
		bare="${raw#\#}"
		case "$bare" in ''|*[!0-9]*) die "issue '$number' does not belong to tracker $selected" ;; esac
		if [ "$backend" = jira ]; then
			project="$(printf '%s' "$tracker" | jq -r '.project // .ref')"
			native="$(printf '%s' "$project" | tr '[:lower:]' '[:upper:]')-${bare}"
		else
			native="$bare"
		fi
	fi
else
	if [ ${#candidate_refs[@]} -eq 1 ]; then
		selected="${candidate_refs[0]}"; native="${candidate_numbers[0]}"; tracker="${candidate_json[0]}"
	else
		tracker="$(select_json)"
		selected="$(printf '%s' "$tracker" | jq -r '.ref')"
		backend="$(printf '%s' "$tracker" | jq -r '.backend | ascii_downcase')"
		bare="${raw#\#}"
		case "$bare" in ''|*[!0-9]*) die "unknown tracker in '$number'; choose a configured ref/alias or use --tracker" ;; esac
		if [ "$backend" = jira ]; then
			project="$(printf '%s' "$tracker" | jq -r '.project // .ref')"
			native="$(printf '%s' "$project" | tr '[:lower:]' '[:upper:]')-${bare}"
		else
			native="$bare"
		fi
	fi
fi

backend="$(printf '%s' "$tracker" | jq -r '.backend | ascii_downcase')"
if [ "$backend" = jira ]; then qualified="${selected}-${native##*-}"; else qualified="${selected}-${native}"; fi
branch_prefix="$(lower "$qualified")"
jq -nc --arg tracker "$selected" --arg number "$native" --arg qualified "$qualified" --arg branchPrefix "$branch_prefix" \
	'{tracker:$tracker, number:$number, qualified:$qualified, branchPrefix:$branchPrefix}'
