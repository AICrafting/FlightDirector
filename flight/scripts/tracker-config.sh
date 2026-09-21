#!/usr/bin/env bash
# Named issue tracker configuration helper (schema 3) — internal to the dispatcher.
#
#   tracker-config.sh validate        --config FILE
#   tracker-config.sh select          --config FILE [--tracker SEL]
#   tracker-config.sh resolve         --config FILE --number INPUT [--tracker SEL]
#   tracker-config.sh legacy-ref      --config FILE
#   tracker-config.sh migrate-config  --in FILE --out FILE --ref REF --credential code|own
#   tracker-config.sh overlay-local   --tracked FILE --local FILE --out FILE
#   tracker-config.sh migrate-secrets --config FILE --secrets FILE --out FILE
#   tracker-config.sh bind-legacy     --config FILE --metadata FILE --repo-root DIR
#                                     --batches DIR --tracker REF
#
# `validate`, `select` and `resolve` read an already merged (tracked + local) config;
# the dispatcher owns which files are merged and written. This script never prints a
# token: `migrate-secrets` writes one file and says nothing about its contents.
#
# Contract details (field meanings, precedence, error behaviour) are documented in
# flight/references/flight-setup.md ("Named issue trackers") and adapter-contract.md.
set -euo pipefail

# Windows shims (jq CRLF, path form); a no-op elsewhere.
# shellcheck source-path=SCRIPTDIR source=_portable.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_portable.sh"

die() { echo "flight: $*" >&2; exit 1; }
note() { echo "flight: $*" >&2; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# The backend value an older Flight runtime finds in `issues.backend` after migration.
# Pre-schema-3 dispatchers route issue/label verbs through `issues.backend`, so this
# makes them stop with "no 'issues' adapter for backend 'requires-newer-flight'"
# instead of silently acting on the code repository. Schema-3 runtimes ignore it.
TOMBSTONE_BACKEND="requires-newer-flight"

# Shared jq definitions. A tracker ref is a letter followed by letters/digits only,
# so GH1, GH-1 and GH#1 split without guessing where the ref ends.
JQ_DEFS='
	def lc: ascii_downcase;
	def vref: type == "string" and test("^[A-Za-z][A-Za-z0-9]*$");
	def normapi: (. // "") | tostring | sub("/+$"; "");
	def host: {b: ((.backend // "") | tostring | lc), a: (.api | normapi)};
	def target: host + {o: (.owner // null), r: (.repo // null), p: (.project // null)};
	def tombstone: type == "object" and .backend == "'"$TOMBSTONE_BACKEND"'";
	def owncred: (has("credentialRef") | not) or .credentialRef != "code";
'

cmd="${1:-}"; [ $# -gt 0 ] && shift
config=""; selector=""; number=""; in_file=""; out_file=""; ref=""; credential=""
tracked=""; local_file=""; secrets=""; metadata=""; repo_root=""; batches=""
while [ $# -gt 0 ]; do
	[ $# -ge 2 ] || die "tracker-config: $1 needs a value"
	case "$1" in
		--config)     config="$2" ;;
		--tracker)    selector="$2" ;;
		--number)     number="$2" ;;
		--in)         in_file="$2" ;;
		--out)        out_file="$2" ;;
		--ref)        ref="$2" ;;
		--credential) credential="$2" ;;
		--tracked)    tracked="$2" ;;
		--local)      local_file="$2" ;;
		--secrets)    secrets="$2" ;;
		--metadata)   metadata="$2" ;;
		--repo-root)  repo_root="$2" ;;
		--batches)    batches="$2" ;;
		*) die "tracker-config: unknown arg '$1'" ;;
	esac
	shift 2
done
need_file() { [ -n "$2" ] && [ -f "$2" ] || die "tracker-config $cmd: $1 file required (got '${2:-}')"; }

# ── validation ────────────────────────────────────────────────────────────────
# Prints every problem (one per line) so a user can repair the config in one pass.
validation_errors() {
	jq -r "$JQ_DEFS"'
		. as $root
		| if (.issueTrackers | type) != "array" or (.issueTrackers | length) == 0 then
			"issueTrackers must be a non-empty array of tracker objects"
		  else
			(.issueTrackers | to_entries[] | .key as $i | .value as $t
			 | ("issueTrackers[\($i)]" + (if ($t | type) == "object" and ($t.ref | vref) then " (\($t.ref))" else "" end)) as $at
			 | if ($t | type) != "object" then "\($at): must be an object"
			   else
				(if ($t.ref | vref) | not then "\($at): ref must start with a letter and contain only letters and digits (e.g. GH, FJ, PROJ)" else empty end),
				(if ($t.ref | vref) and ($t.ref | lc) == "code" then "\($at): ref \"code\" is reserved for the code credential" else empty end),
				(if ($t.name | type) != "string" or ($t.name | length) == 0 then "\($at): name must be a non-empty string" else empty end),
				(if ($t.backend | type) != "string" or ($t.backend | length) == 0 then "\($at): backend must be a non-empty string" else empty end),
				(if ($t | has("default")) and (($t.default | type) != "boolean") then "\($at): default must be true or false" else empty end),
				(if ($t | has("aliases")) and ((($t.aliases | type) != "array") or (($t.aliases | all(vref)) | not))
				 then "\($at): aliases must be an array of refs (a letter, then letters and digits)" else empty end),
				(if ($t | has("labels")) and (($t.labels | type) != "object") then "\($at): labels must be an object" else empty end),
				(if ($t | has("credentialRef")) then
					if ($t.credentialRef | type) != "string" then "\($at): credentialRef must be a string"
					elif $t.credentialRef == "code" then
						if ($t | host) != ($root.code // {} | host)
						then "\($at): credentialRef \"code\" reuses the code token only for a tracker on the same backend and api host as code; give this tracker its own credential (omit credentialRef) instead"
						else empty end
					elif $t.credentialRef != $t.ref then "\($at): credentialRef must be omitted, the tracker'"'"'s own ref (\($t.ref)), or \"code\""
					else empty end
				 else empty end)
			   end),
			([.issueTrackers[] | objects | select(.default == true)] | length) as $n
			| (if $n != 1 then "exactly one tracker must have \"default\": true (found \($n))" else empty end),
			([.issueTrackers[] | objects | (.ref, ((.aliases // []) | if type == "array" then .[] else empty end))
			  | strings | lc] | group_by(.) | map(select(length > 1) | .[0])[]
			 | "ref/alias \"\(.)\" is used more than once (refs and aliases are compared case-insensitively)")
		  end,
		  (if has("labels") then "top-level labels is the pre-schema-3 form; it belongs inside the tracker entry (run flight reconcile, or move it by hand)" else empty end),
		  (if has("issues") and ((.issues | tombstone) | not) then "the pre-schema-3 issues object sits beside issueTrackers; remove it (its settings belong in a tracker entry)" else empty end),
		  (if has("legacyIssueTracker") and ((.legacyIssueTracker | vref) | not) then "legacyIssueTracker must be a tracker ref" else empty end)
	' "$1"
}

validate() {
	local errs
	jq -e . "$1" >/dev/null 2>&1 || die "config is not valid JSON"
	errs="$(validation_errors "$1")"
	[ -z "$errs" ] || die "invalid issueTrackers configuration:
$(printf '%s\n' "$errs" | sed 's/^/  - /')"
}

# ── selection & resolution ────────────────────────────────────────────────────
# "FJ, ALT (alias Ext), JIR (Jira project PROJ)" — for error messages.
describe_trackers() {
	jq -r '[.issueTrackers[]
		| .ref
		  + (if ((.aliases // []) | length) > 0 then " (alias " + ((.aliases) | join(", ")) + ")" else "" end)
		  + (if (.backend | ascii_downcase) == "jira" and (.project // "") != "" and .project != .ref then " (Jira project " + .project + ")" else "" end)
		  + (if .default == true then " [default]" else "" end)
	] | join(", ")' "$config"
}

# Edit distance ≤ 1, or one a prefix of the other: close enough to suggest, never to pick.
suggest() {
	local want; want="$(lower "$1")"
	jq -r '.issueTrackers[] | (.ref, ((.aliases // [])[]), (if (.backend | ascii_downcase) == "jira" then (.project // empty) else empty end))' "$config" \
		| awk -v w="$want" '
			function lev(a, b,    i, j, la, lb, d, c, x, y, z) {
				la = length(a); lb = length(b)
				for (i = 0; i <= la; i++) d[i, 0] = i
				for (j = 0; j <= lb; j++) d[0, j] = j
				for (i = 1; i <= la; i++) for (j = 1; j <= lb; j++) {
					c = (substr(a, i, 1) == substr(b, j, 1)) ? 0 : 1
					x = d[i-1, j] + 1; y = d[i, j-1] + 1; z = d[i-1, j-1] + c
					d[i, j] = (x < y ? (x < z ? x : z) : (y < z ? y : z))
				}
				return d[la, lb]
			}
			{ id = tolower($0) }
			id != "" && (lev(id, w) <= 1 || index(id, w) == 1 || index(w, id) == 1) && !seen[$0]++ { out = out (out == "" ? "" : ", ") $0 }
			END { print out }'
}

unknown_tracker() {
	local what="$1" name="$2" hint
	hint="$(suggest "$name")"
	# shellcheck disable=SC2016  # the quotes are literal message text
	die "unknown tracker '$name'${what:+ in '$what'}${hint:+ — did you mean $hint?} Configured trackers: $(describe_trackers). Choose one explicitly (REF-N or --tracker REF); flight never guesses."
}

select_json() {
	local out
	if [ -n "$selector" ]; then
		out="$(jq -c --arg s "$(lower "$selector")" '
			[.issueTrackers[] | select((.ref | ascii_downcase) == $s or any((.aliases // [])[]; ascii_downcase == $s))]
			| if length == 1 then .[0] else empty end' "$config")"
		[ -n "$out" ] || unknown_tracker "" "$selector"
	else
		out="$(jq -c '[.issueTrackers[] | select(.default == true)] | if length == 1 then .[0] else empty end' "$config")"
		[ -n "$out" ] || die "issueTrackers must contain exactly one default"
	fi
	printf '%s\n' "$out"
}

# native_for <tracker-json> <digits> — the adapter-facing issue id for a numeric suffix.
native_for() {
	local t="$1" n="$2" backend project
	backend="$(jq -r '.backend | ascii_downcase' <<<"$t")"
	if [ "$backend" = jira ]; then
		project="$(jq -r '.project // .ref' <<<"$t")"
		printf '%s-%s\n' "$(upper "$project")" "$n"
	else
		printf '%s\n' "$n"
	fi
}

strip_zeros() {
	local n="${1#"${1%%[!0]*}"}"
	[ -n "$n" ] || die "issue number must be positive (got '$1')"
	printf '%s\n' "$n"
}

resolve() {
	local raw_l tref tbackend tproject taliases tjson tokens token token_l digits seen existing i
	local selected="" native="" tracker="" bare prefix
	local cand_refs=() cand_digits=() cand_json=()
	[ -n "$number" ] || die "issues resolve: --number required"
	raw_l="$(lower "$number")"

	# Every configured ref, alias and Jira project key is a candidate prefix. A tracker
	# is a candidate at most once, even when its ref and an alias both match.
	while IFS=$'\x1f' read -r tref tbackend tproject taliases tjson; do
		[ -n "$tref" ] || continue
		tokens="$tref"
		[ -z "$taliases" ] || tokens="$tokens,$taliases"
		if [ "$tbackend" = jira ] && [[ "$tproject" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]; then tokens="$tokens,$tproject"; fi
		local old_ifs="$IFS"; IFS=,
		for token in $tokens; do
			token_l="$(lower "$token")"
			if [[ "$raw_l" =~ ^${token_l}[-#]?([0-9]+)$ ]]; then
				digits="${BASH_REMATCH[1]}"
				seen=0
				for existing in ${cand_refs[@]+"${cand_refs[@]}"}; do
					if [ "$existing" = "$tref" ]; then seen=1; fi
				done
				if [ "$seen" = 0 ]; then cand_refs+=("$tref"); cand_digits+=("$digits"); cand_json+=("$tjson"); fi
			fi
		done
		IFS="$old_ifs"
	done < <(jq -r '.issueTrackers[] | [.ref, (.backend | ascii_downcase), (.project // ""), ((.aliases // []) | join(",")), tojson] | join("\u001f")' "$config")

	if [ -n "$selector" ]; then
		tracker="$(select_json)"
		selected="$(jq -r '.ref' <<<"$tracker")"
		if [ ${#cand_refs[@]} -gt 0 ]; then
			# An explicit selector may pick one of several candidate splits, but it can
			# never override a qualified input that names a different tracker.
			for i in "${!cand_refs[@]}"; do
				if [ "${cand_refs[$i]}" = "$selected" ]; then
					native="$(native_for "$tracker" "$(strip_zeros "${cand_digits[$i]}")")"
				fi
			done
			[ -n "$native" ] || die "--tracker $selector conflicts with qualified issue '$number' (which names ${cand_refs[*]})"
		else
			bare="${number#\#}"
			case "$bare" in
				''|*[!0-9]*) prefix="$(printf '%s' "$number" | sed -E 's/[-#]?[0-9]+$//')"
					[ "$prefix" != "$number" ] && [ -n "$prefix" ] || die "issue '$number' is not an issue number or a qualified REF-N"
					die "issue '$number' does not belong to tracker $selected: '$prefix' is not its ref, an alias, or its Jira project" ;;
			esac
			native="$(native_for "$tracker" "$(strip_zeros "$bare")")"
		fi
	else
		if [ ${#cand_refs[@]} -gt 1 ]; then
			local list; list="$(printf '%s, ' "${cand_refs[@]}")"; list="${list%, }"
			die "ambiguous issue '$number': it reads as an issue on more than one tracker ($list); pick one with --tracker REF"
		elif [ ${#cand_refs[@]} -eq 1 ]; then
			selected="${cand_refs[0]}"; tracker="${cand_json[0]}"
			native="$(native_for "$tracker" "$(strip_zeros "${cand_digits[0]}")")"
		else
			bare="${number#\#}"
			case "$bare" in
				''|*[!0-9]*)
					prefix="$(printf '%s' "$number" | sed -E 's/[-#]?[0-9]+$//')"
					[ "$prefix" != "$number" ] && [ -n "$prefix" ] || die "issue '$number' is not an issue number or a qualified REF-N"
					unknown_tracker "$number" "$prefix" ;;
			esac
			tracker="$(select_json)"
			selected="$(jq -r '.ref' <<<"$tracker")"
			native="$(native_for "$tracker" "$(strip_zeros "$bare")")"
		fi
	fi

	local qualified="${selected}-${native##*-}"
	jq -nc --arg tracker "$selected" --arg number "$native" --arg qualified "$qualified" --arg branchPrefix "$(lower "$qualified")" \
		'{tracker:$tracker, number:$number, qualified:$qualified, branchPrefix:$branchPrefix}'
}

# ── migration ─────────────────────────────────────────────────────────────────
# The default tracker's ref for a pre-schema-3 config: Jira's project key when it is
# a valid ref, otherwise the backend shorthand (GH, FJ, GL).
legacy_ref() {
	local backend project
	backend="$(jq -r '((.issues.backend // .code.backend) // "") | ascii_downcase' "$config")"
	project="$(jq -r '(.issues.project // .code.project) // empty' "$config")"
	if [ "$backend" = jira ] && [[ "$project" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] && [ "$(lower "$project")" != code ]; then
		upper "$project"; echo; return
	fi
	case "$backend" in
		forgejo|gitea) echo FJ ;;
		github)  echo GH ;;
		gitlab)  echo GL ;;
		jira)    echo JIRA ;;
		''|none) die "cannot migrate the issue tracker: neither issues.backend nor code.backend names a tracker backend" ;;
		*)
			project="$(printf '%s' "$backend" | tr -cd '[:alnum:]' | tr '[:lower:]' '[:upper:]')"
			[[ "$project" =~ ^[A-Z][A-Z0-9]*$ ]] || die "cannot derive a tracker ref from backend '$backend'"
			printf '%s\n' "$project"
			;;
	esac
}

# Legacy effective issue axis → one default tracker. `issues` fields win over the
# code coordinates they used to inherit; only coordinates are inherited — stage
# policy, signature, preflight and every other code setting stay on `code`.
# Unknown issue fields and explicit false/null values ride along untouched.
migrate_config() {
	jq --arg ref "$ref" --arg cred "$credential" --arg tomb "$TOMBSTONE_BACKEND" "$JQ_DEFS"'
		def display: {forgejo:"Forgejo", gitea:"Gitea", github:"GitHub", gitlab:"GitLab", jira:"Jira"}[lc] // .;
		((.code // {}) | with_entries(select(.key as $k | ["backend","api","owner","repo","project","email"] | index($k)))) as $inherited
		| ($inherited * ((.issues // {}) | if type == "object" then . else {} end)) as $old
		| ($old
			+ {ref: $ref,
			   name: ($old.name // "\($old.backend | tostring | display) issues"),
			   default: true,
			   credentialRef: (if $cred == "code" then "code" else $ref end),
			   labels: (.labels // $old.labels // {})}) as $tracker
		| del(.labels)
		| .issues = {backend: $tomb, note: "Issue trackers moved to issueTrackers (config schema 3). Update the Flight plugin; this stub only stops older versions from using the wrong tracker."}
		| .issueTrackers = [$tracker]
		| .legacyIssueTracker = $ref
	' "$in_file" >"$out_file"
}

# A machine-local override that still speaks the legacy form (or that changes code
# coordinates the default tracker used to inherit) becomes a complete local
# `issueTrackers` array — config.local.json arrays replace wholesale, so a partial
# entry would erase the tracked trackers. The tracked ref is kept, so branch names
# stay the same on every clone. When the override changes nothing about the
# trackers, no array is written and future tracked edits keep flowing through.
overlay_local() {
	jq -s --arg tomb "$TOMBSTONE_BACKEND" "$JQ_DEFS"'
		.[0] as $tracked | .[1] as $local
		| ["backend","api","owner","repo","project","email"] as $coords
		| (($tracked.code // {}) * ($local.code // {})) as $mergedCode
		| (($local.code // {}) | with_entries(select(.key as $k | $coords | index($k)))) as $localCoords
		| (($local.issues // {}) | if type == "object" and (tombstone | not) then . else {} end) as $localIssues
		| ($tracked.issueTrackers
			| map(
				if .default == true then
					. as $t
					| (if ($t | target) == ($tracked.code // {} | target) then $t * $localCoords else $t end)
					| . * ($localIssues | del(.labels))
					| .labels = (($t.labels // {}) * ($local.labels // {}) * ($localIssues.labels // {}))
					| (if .credentialRef == "code" and ((host) != ($mergedCode | host)) then .credentialRef = .ref else . end)
				else . end)) as $effective
		| $local | del(.labels)
		| (if has("issues") and ((.issues | tombstone) | not) then del(.issues) else . end)
		| if has("issueTrackers") then .
		  elif $effective != $tracked.issueTrackers then .issueTrackers = $effective
		  else . end
	' "$tracked" "$local_file" >"$out_file"
}

# Legacy secrets (a top-level `issues` object, or no `issueTrackers` map yet) →
# credentials keyed by tracker ref. Code credentials are never moved. The legacy
# issue credential goes to the default tracker; the code token is copied only for a
# default tracker with its own credential on the SAME host as code (exactly what the
# old code→issues fallback sent there). Everything else is left for the user.
migrate_secrets() {
	jq -s "$JQ_DEFS"'
		.[0] as $cfg | .[1] as $sec
		| ($cfg.issueTrackers | map(select(.default == true)) | .[0]) as $d
		| ($sec.issueTrackers // {}) as $have
		| $sec
		| .issueTrackers = $have
		| if ($sec.issues | type) == "object" then
			(if $have[$d.ref] == null then .issueTrackers[$d.ref] = $sec.issues else . end)
		  elif ($d | owncred) and $have[$d.ref] == null and (($sec.code.token // "") != "")
			and (($d | host) == ($cfg.code // {} | host)) then
			.issueTrackers[$d.ref] = $sec.code
		  else . end
		| del(.issues)
	' "$config" "$secrets" >"$out_file"
	if jq -e -s '.[0] as $cfg | .[1] as $sec
		| ($cfg.issueTrackers | map(select(.default == true)) | .[0]) as $d
		| (($d | has("credentialRef") | not) or $d.credentialRef != "code") and (($sec.issueTrackers[$d.ref].token // "") == "")' \
		"$config" "$out_file" >/dev/null; then
		note "notice — tracker $(jq -r '.issueTrackers[] | select(.default == true) | .ref' "$config") uses its own credential but secrets has no .issueTrackers[\"$(jq -r '.issueTrackers[] | select(.default == true) | .ref' "$config")\"].token yet; add one (then flight auth check --tracker REF)."
	fi
}

# Durable local bindings for pre-schema-3 work: every unqualified issue branch
# (local heads and remote-tracking refs) and every existing batch manifest belongs to
# the tracker that was the default at migration. Written once, merged on retry, and
# never re-pointed: a conflicting legacyDefaultTracker is a repairable error.
bind_legacy() {
	local lock="$metadata.lock" tries=0 branches manifests tmp existing_ref
	[ -n "$metadata" ] && [ -n "$repo_root" ] && [ -n "$ref" ] || die "bind-legacy: --metadata, --repo-root and --tracker are required"
	[[ "$ref" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || die "bind-legacy: invalid tracker ref '$ref'"
	mkdir -p "$(dirname "$metadata")"
	while ! mkdir "$lock" 2>/dev/null; do
		tries=$((tries + 1))
		[ "$tries" -lt 200 ] || die "timed out waiting for the work-items lock ($lock); remove it if no other flight process is running"
		sleep 0.05
	done
	# shellcheck disable=SC2064  # expand now: the lock path is fixed for this process
	trap "rmdir '$lock' 2>/dev/null || true" EXIT

	if [ -f "$metadata" ]; then
		jq -e 'type == "object"' "$metadata" >/dev/null 2>&1 || die "$metadata is not a JSON object; repair or remove it and re-run flight reconcile"
		existing_ref="$(jq -r '.legacyDefaultTracker // empty' "$metadata")"
		if [ -n "$existing_ref" ] && [ "$(lower "$existing_ref")" != "$(lower "$ref")" ]; then
			die "legacy work is already bound to tracker '$existing_ref' in $metadata, not '$ref'; fix legacyIssueTracker in the config or the metadata file, then re-run flight reconcile"
		fi
	fi

	branches="$(git -C "$repo_root" for-each-ref --format='%(refname)' refs/heads refs/remotes 2>/dev/null \
		| sed -E -e 's#^refs/heads/##' -e 's#^refs/remotes/[^/]+/##' \
		| grep -E '^[^/]+/[0-9]+(-|$)' | sort -u || true)"
	manifests=""
	if [ -n "$batches" ] && [ -d "$batches" ]; then
		manifests="$(find "$batches" -maxdepth 1 -type f -name '*.json' 2>/dev/null \
			| sed -e 's#.*/##' -e 's#\.json$##' | sort -u || true)"
	fi

	tmp="$(mktemp "$metadata.tmp.XXXXXX")"
	{ [ -f "$metadata" ] && cat "$metadata" || echo '{}'; } | jq \
		--arg t "$ref" --arg branches "$branches" --arg manifests "$manifests" --slurpfile cfg "$config" '
		($cfg[0].issueTrackers[] | select((.ref | ascii_downcase) == ($t | ascii_downcase))) as $tr
		| def ident($n):
			(if ($tr.backend | ascii_downcase) == "jira" then (($tr.project // $tr.ref) | ascii_upcase) + "-" + $n else $n end) as $native
			| {tracker: $tr.ref, number: $native, qualified: ($tr.ref + "-" + $n), branchPrefix: (($tr.ref + "-" + $n) | ascii_downcase)};
		.schemaVersion = (.schemaVersion // 1)
		| .legacyDefaultTracker = (.legacyDefaultTracker // $tr.ref)
		| .branches = (.branches // {})
		| .manifests = (.manifests // {})
		| reduce ($branches | split("\n")[] | select(length > 0)) as $b (.;
			if .branches[$b] then . else
				.branches[$b] = (ident($b | sub("^[^/]+/"; "") | capture("^0*(?<n>[1-9][0-9]*|0)").n) + {legacy: true})
			end)
		| reduce ($manifests | split("\n")[] | select(length > 0)) as $m (.;
			if .manifests[$m] then . else .manifests[$m] = {tracker: $tr.ref, legacy: true} end)
	' >"$tmp" || { rm -f "$tmp"; die "could not write legacy work bindings to $metadata"; }
	mv "$tmp" "$metadata"
	rmdir "$lock" 2>/dev/null || true
	trap - EXIT
}

case "$cmd" in
	validate)        need_file --config "$config"; validate "$config" ;;
	select)          need_file --config "$config"; select_json ;;
	resolve)         need_file --config "$config"; resolve ;;
	legacy-ref)      need_file --config "$config"; legacy_ref ;;
	migrate-config)
		need_file --in "$in_file"; [ -n "$out_file" ] || die "migrate-config: --out required"
		[[ "$ref" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || die "migrate-config: invalid --ref '$ref'"
		case "$credential" in code|own) ;; *) die "migrate-config: --credential must be code or own" ;; esac
		migrate_config ;;
	overlay-local)
		need_file --tracked "$tracked"; need_file --local "$local_file"; [ -n "$out_file" ] || die "overlay-local: --out required"
		overlay_local ;;
	migrate-secrets)
		need_file --config "$config"; need_file --secrets "$secrets"; [ -n "$out_file" ] || die "migrate-secrets: --out required"
		migrate_secrets ;;
	bind-legacy)     need_file --config "$config"; ref="$selector"; bind_legacy ;;
	*) die "tracker-config: unknown command '${cmd}' (validate select resolve legacy-ref migrate-config overlay-local migrate-secrets bind-legacy)" ;;
esac
