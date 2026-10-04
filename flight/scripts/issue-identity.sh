#!/usr/bin/env bash
#
# issue-identity.sh — the ONE place flight's workflow scripts and skills turn a branch
# name, a batch-manifest entry or a history reference into a retained issue identity
# (#198). An identity is exactly what `flight issues resolve` prints:
#
#   {"tracker":"FJ","number":"12","qualified":"FJ-12","display":"FJ-12","branchPrefix":"fj-12"}
#
# (`number` is the tracker's native id — `PROJ-12` for Jira.) `qualified` is the routing
# key and never changes; `display` is the name people and commits see — `#12` (or
# `PROJ-7`) while the repo has a single tracker (#258), the qualified id otherwise. It
# is re-derived on every output, so a retained identity never shows a stale form. Everything here is
# resolved through the dispatcher, so parsing rules are never duplicated. Needs config
# schema 3 (named issue trackers); run `flight reconcile` first.
#
#   issue-identity.sh from-branch   --branch NAME [--tracker REF]
#   issue-identity.sh from-manifest --run-id ID --entry N
#   issue-identity.sh from-history  --ref REF    [--tracker REF]
#   issue-identity.sh remember      --branch NAME --identity JSON
#   issue-identity.sh pr-reference  --identity JSON --closes true|false
#
# Exit status: 0 = identity printed; 3 = the input carries no issue identity (a
# non-issue branch); 4 = a legacy unqualified branch/entry/reference whose tracker
# cannot be recovered — rerun with --tracker REF (never guessed from the current
# default); 1 = any other error.
#
# Legacy bindings live in <config dir>/batches/work-items/identities.json, written by
# `flight reconcile` at migration (see references/flight-setup.md). This helper reads
# them and adds non-legacy entries (`remember`) under the same lock protocol; it never
# re-points an existing entry. Only unqualified work that predates the migration uses
# the file's `legacyDefaultTracker` — a bare number a person types is resolved by
# `flight issues resolve` against the CURRENT default instead.
set -euo pipefail

# Windows shims (jq CRLF, path form); a no-op elsewhere. Without it a native jq.exe's
# values keep a trailing \r: the schema check, the tracker lookups and the pr-reference
# comparison all fail against an invisible byte.
# shellcheck source-path=SCRIPTDIR source=_portable.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_portable.sh"

die() { printf 'issue-identity: %s\n' "$1" >&2; exit "${2:-1}"; }
command -v jq >/dev/null 2>&1 || die "jq is required"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLIGHT="${FLIGHT_SELF:-$SELF_DIR/flight}"

if [ -n "${FLIGHT_REPO_ROOT:-}" ]; then
	ROOT="$FLIGHT_REPO_ROOT"
else
	COMMON="$(git rev-parse --git-common-dir 2>/dev/null)" || die "not inside a git repository"
	ROOT="$(dirname "$(cd "$COMMON" && pwd)")"
fi
# Same config-home resolution as the dispatcher (`.lightspeed/` is the deprecated one).
CFG_DIR="$ROOT/.flightdirector"
[ -f "$CFG_DIR/config.json" ] || { [ -f "$ROOT/.lightspeed/config.json" ] && CFG_DIR="$ROOT/.lightspeed"; } || true
FILE="$CFG_DIR/batches/work-items/identities.json"
LOCK="$FILE.lock"

flight() { (cd "$ROOT" && "$FLIGHT" "$@"); }

schema="$(jq -r '.schemaVersion // 1' "$CFG_DIR/config.json" 2>/dev/null || echo 0)"
[ "$schema" -ge 3 ] 2>/dev/null \
	|| die "retained issue identities need config schema 3 (named issue trackers); run flight reconcile --harness claude|codex first"

bindings() { if [ -f "$FILE" ]; then cat "$FILE"; else echo '{}'; fi; }

valid_identity() {
	jq -e 'type == "object" and ([.tracker, .number, .qualified, .branchPrefix] | all(type == "string" and length > 0))' \
		<<<"$1" >/dev/null 2>&1
}

# The canonical keys, compact — `legacy` and any other metadata are dropped, so a
# reconcile-bound entry and a fresh `issues resolve` compare equal. `display` is never
# taken from the input: it depends on how many trackers the repo has NOW, so it is
# derived here (one resolve per process, cached). Fails on anything that is not an
# identity: a failed `resolve` inside `$(canonical "$(resolve …)")` hands it an empty
# string, and printing nothing with status 0 would pass for success.
UNPREFIXED=""
canonical() {
	valid_identity "$1" || return 1
	if [ -z "$UNPREFIXED" ]; then
		# A tracker that has since left the config cannot be resolved; show it qualified.
		UNPREFIXED="$(resolve "$(jq -r '.qualified' <<<"$1")" 2>/dev/null | jq -r 'if .display then .display != .qualified else false end')" \
			|| UNPREFIXED=false
	fi
	jq -c --argjson u "$UNPREFIXED" '{tracker, number, qualified,
		display: (if $u then (if (.number | test("^[0-9]+$")) then "#" + .number else .number end) else .qualified end),
		branchPrefix}' <<<"$1"
}

resolve() { # resolve <input> [tracker]
	if [ -n "${2:-}" ]; then flight issues resolve --number "$1" --tracker "$2"
	else flight issues resolve --number "$1"; fi
}

# sole_tracker — the ref of the repo's only tracker, or nothing when it has several.
sole_tracker() { flight config 'if (.issueTrackers // [] | length) == 1 then .issueTrackers[0].ref else empty end' 2>/dev/null || true; }

# canonical_ref <selector> — the configured ref a ref-or-alias names (dispatcher-checked).
canonical_ref() { flight issues tracker --tracker "$1" | jq -r '.ref'; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

with_lock() { # with_lock <cmd…> — the reconcile lock protocol: mkdir dir, 200 × 0.05 s
	local tries=0 rc=0
	mkdir -p "$(dirname "$FILE")"
	while ! mkdir "$LOCK" 2>/dev/null; do
		tries=$((tries + 1))
		[ "$tries" -lt 200 ] || die "timed out waiting for the work-items lock ($LOCK); remove it if no other flight process is running"
		sleep 0.05
	done
	# shellcheck disable=SC2064  # expand now: the lock path is fixed for this process
	trap "rmdir '$LOCK' 2>/dev/null || true" EXIT
	"$@" || rc=$?
	rmdir "$LOCK" 2>/dev/null || true
	trap - EXIT
	return "$rc"
}

# ── remember ──────────────────────────────────────────────────────────────────
write_binding() { # write_binding <branch> <canonical identity>
	local data old tmp
	data="$(bindings)"
	jq -e 'type == "object"' <<<"$data" >/dev/null 2>&1 || die "$FILE is not a JSON object; repair it before binding work"
	old="$(jq -c --arg b "$1" '.branches[$b] // empty' <<<"$data")"
	if [ -n "$old" ]; then
		[ "$(canonical "$old")" = "$2" ] && return 0
		die "branch '$1' is already bound to $(jq -r '.qualified' <<<"$old"); bindings are never re-pointed"
	fi
	tmp="$(mktemp "$FILE.tmp.XXXXXX")"
	jq --arg b "$1" --argjson i "$2" '
		.schemaVersion = (.schemaVersion // 1)
		| .branches = ((.branches // {}) + {($b): ($i | del(.display))})
		| .manifests = (.manifests // {})' <<<"$data" >"$tmp" || { rm -f "$tmp"; die "could not write $FILE"; }
	mv "$tmp" "$FILE"
}

remember() { # remember <branch> <identity>
	local branch="$1" id="$2" want slug prefix num
	valid_identity "$id" || die "--identity must be the JSON flight issues resolve prints (tracker, number, qualified, branchPrefix)"
	id="$(canonical "$id")"
	# Round-trip through the resolver so nothing hand-built (or stale) is retained.
	want="$(canonical "$(resolve "$(jq -r '.number' <<<"$id")" "$(jq -r '.tracker' <<<"$id")")")" \
		|| die "cannot verify identity $(jq -r '.qualified' <<<"$id")"
	[ "$want" = "$id" ] || die "identity $id does not match the resolver's $want"
	# A qualified branch name must carry this identity's prefix; an unqualified one
	# (feature/12-…: legacy, or a single-tracker repo's, #258) this identity's number.
	slug="${branch#*/}"; prefix="$(jq -r '.branchPrefix' <<<"$id")"
	if [[ "$slug" =~ ^[A-Za-z][A-Za-z0-9]*-[0-9]+(-|$) ]]; then
		case "$(lower "$slug")" in "$prefix"|"$prefix"-*) ;; *) die "branch '$branch' does not carry $prefix";; esac
	elif [[ "$slug" =~ ^0*([0-9]+)(-|$) ]]; then
		num="$(jq -r '.number' <<<"$id")"
		[ "${BASH_REMATCH[1]}" = "${num##*-}" ] || die "branch '$branch' does not carry issue $(jq -r '.qualified' <<<"$id")"
	fi
	with_lock write_binding "$branch" "$id"
}

# ── from-branch ───────────────────────────────────────────────────────────────
from_branch() { # from_branch <branch> [explicit tracker]
	local branch="$1" explicit="${2:-}" bound slug n tracker id
	branch="${branch#refs/heads/}"
	bound="$(bindings | jq -c --arg b "$branch" '.branches[$b] // empty' 2>/dev/null || true)"
	if [ -n "$bound" ] && valid_identity "$bound"; then
		if [ -n "$explicit" ] && [ "$(canonical_ref "$explicit")" != "$(jq -r '.tracker' <<<"$bound")" ]; then
			die "--tracker $explicit conflicts with $branch's retained identity $(jq -r '.qualified' <<<"$bound")"
		fi
		canonical "$bound"
		return 0
	fi
	slug="${branch#*/}"
	[ "$slug" != "$branch" ] || die "branch '$branch' carries no issue identity" 3
	if [[ "$slug" =~ ^([A-Za-z][A-Za-z0-9]*)-([0-9]+)(-|$) ]]; then
		# Qualified (feature/fj-12-…): self-describing — refs are stable forever, so the
		# current default never matters. A prefix that names no tracker is not an issue.
		local ref="${BASH_REMATCH[1]}" num="${BASH_REMATCH[2]}" err
		err="$(mktemp "${TMPDIR:-/tmp}/issue-identity.XXXXXX")"
		if ! id="$(resolve "$ref-$num" "$explicit" 2>"$err")"; then
			# An explicit selector that disagrees with the branch is an error, not "no issue".
			if grep -Eq 'conflicts|does not belong' "$err"; then cat "$err" >&2; rm -f "$err"; exit 1; fi
			rm -f "$err"
			die "branch '$branch' carries no issue identity (no configured tracker '$ref')" 3
		fi
		rm -f "$err"
		canonical "$id"
		return 0
	fi
	if [[ "$slug" =~ ^([0-9]+)(-|$) ]]; then
		# Unqualified (feature/12-…): bound when it was started (remember) or at
		# migration, else the migrated original default, else the repo's ONLY tracker
		# (#258 names single-tracker branches this way) — never the current default
		# among several.
		n="${BASH_REMATCH[1]}"
		tracker="$explicit"
		[ -n "$tracker" ] || tracker="$(bindings | jq -r '.legacyDefaultTracker // empty' 2>/dev/null || true)"
		[ -n "$tracker" ] || tracker="$(sole_tracker)"
		[ -n "$tracker" ] || die "legacy branch '$branch' has no recoverable tracker binding; rerun with --tracker REF (flight never guesses)" 4
		id="$(canonical "$(resolve "$n" "$tracker")")"
		# An explicit choice is retained, so every later step agrees without asking again.
		[ -z "$explicit" ] || with_lock write_binding "$branch" "$id"
		printf '%s\n' "$id"
		return 0
	fi
	die "branch '$branch' carries no issue identity" 3
}

# ── from-manifest ─────────────────────────────────────────────────────────────
from_manifest() { # from_manifest <run id> <legacy entry>
	local run="$1" entry="$2" tracker
	[[ "$entry" =~ ^#?[0-9]+$ ]] || die "legacy manifest entry '$entry' is not an issue number"
	tracker="$(bindings | jq -r --arg r "$run" '.manifests[$r].tracker // .legacyDefaultTracker // empty' 2>/dev/null || true)"
	[ -n "$tracker" ] || die "legacy manifest '$run' has no recoverable tracker binding for issue $entry" 4
	canonical "$(resolve "${entry#\#}" "$tracker")"
}

# SAME_TARGET — jq `same_target($code; $tracker)`: true when the tracker is the code
# repository's own issue tracker — same backend, same api (trailing / ignored), same
# owner/repo. Only those issues get closing keywords in a code PR. A Jira tracker never
# is one: its issues cannot live in a forge repository.
# shellcheck disable=SC2016  # jq program: $c, $t, $k are jq variables
SAME_TARGET='
	def norm: (. // "") | tostring | sub("/+$"; "") | ascii_downcase;
	def same_target($c; $t):
		def same($k): ($c[$k] | norm) != "" and ($c[$k] | norm) == ($t[$k] | norm);
		($t.backend | norm) != "jira" and ($c.backend | norm) != "jira"
		and same("backend") and same("api") and same("owner") and same("repo");'

# code_repo_trackers — the refs (one per line) of every tracker that is the code
# repository's own issue tracker.
code_repo_trackers() {
	local cfg
	cfg="$(flight config '{code: (.code // {}), trackers: (.issueTrackers // [])}')" || return 1
	jq -r "$SAME_TARGET"' . as $x | $x.trackers[] | select(same_target($x.code; .)) | .ref' <<<"$cfg"
}

# ── from-history ──────────────────────────────────────────────────────────────
# A reference found in persisted history — a commit subject, a merge message, an old
# PR body. Qualified references resolve to their own tracker. A bare #N has two
# sources: history from before the migration (the legacy tracker), and PR bodies
# written since, which still say `Closes #N`/`Ready #N` for the code repository's OWN
# tracker (see pr-reference). So a bare #N maps to the legacy tracker only when those
# two agree — no code-repo tracker, or the code-repo tracker IS the legacy one. When
# they differ it is ambiguous (4): the caller asks and passes --tracker. A repo that
# never migrated (no binding default and no `legacyIssueTracker` — set up on schema 3)
# has no pre-migration history, so its one code-repo tracker is the only writer. A
# migrated repo whose binding default is missing (4) cannot tell.
from_history() { # from_history <ref> [explicit tracker]
	local ref="$1" explicit="${2:-}" tracker legacy code_refs
	if [[ "$ref" =~ ^#?[0-9]+$ ]]; then
		tracker="$explicit"
		if [ -z "$tracker" ]; then
			legacy="$(bindings | jq -r '.legacyDefaultTracker // empty' 2>/dev/null || true)"
			code_refs="$(code_repo_trackers)" || die "cannot read the tracker configuration"
			if [ -z "$code_refs" ]; then
				tracker="$legacy"
			elif [ -n "$legacy" ] && grep -qixF -- "$legacy" <<<"$code_refs"; then
				tracker="$legacy"
			elif [ -z "$legacy" ] && [ -z "$(flight config '.legacyIssueTracker // empty')" ] \
				&& [ "$(grep -c . <<<"$code_refs")" = 1 ]; then
				tracker="$code_refs"
			else
				die "bare reference '$ref' is ambiguous: it may predate the migration (${legacy:-no legacy tracker}) or come from a code PR naming the code repository's tracker ($(tr '\n' ' ' <<<"$code_refs" | sed 's/ $//')); rerun with --tracker REF (flight never guesses)" 4
			fi
		fi
		[ -n "$tracker" ] || die "bare reference '$ref' has no recoverable tracker; rerun with --tracker REF (flight never guesses)" 4
		canonical "$(resolve "${ref#\#}" "$tracker")"
	else
		canonical "$(resolve "$ref" "$explicit")"
	fi
}

# ── pr-reference ──────────────────────────────────────────────────────────────
# The issue line for a code PR body. GitHub/Forgejo/GitLab act on `Closes #N` against
# the PR's OWN repository, so it is emitted only when the issue lives in exactly that
# repository (SAME_TARGET: same backend, same api with trailing / ignored, same
# owner/repo; never Jira). Otherwise the line names the qualified id, which no forge acts on, and the
# promotion drives that tracker explicitly. The id is in backticks (#247): GitHub autolinks
# `GH-12`-shaped text to the PR's own repository's issue 12, and a code span suppresses that.
# No URL, body or ledger is ever printed.
pr_reference() { # pr_reference <identity> <closes>
	local id="$1" closes="$2" code tracker same
	valid_identity "$id" || die "--identity must be the JSON flight issues resolve prints"
	case "$closes" in true|false) ;; *) die "--closes must be true or false";; esac
	code="$(flight config '.code // {}')" || die "cannot read the code config"
	tracker="$(flight issues tracker --tracker "$(jq -r '.tracker' <<<"$id")")" || die "cannot read tracker $(jq -r '.tracker' <<<"$id")"
	same="$(jq -rn --argjson c "$code" --argjson t "$tracker" "$SAME_TARGET"' same_target($c; $t)')"
	if [ "$same" = true ]; then
		if [ "$closes" = true ]; then printf 'Closes #%s\n' "$(jq -r '.number' <<<"$id")"
		else printf 'Ready #%s\n' "$(jq -r '.number' <<<"$id")"; fi
	else
		# shellcheck disable=SC2016  # literal backticks: a code span, not a command substitution
		printf 'Tracks `%s`\n' "$(jq -r '.qualified' <<<"$id")"
	fi
}

# ── args ──────────────────────────────────────────────────────────────────────
cmd="${1:-}"; [ $# -gt 0 ] && shift
branch=""; explicit=""; identity=""; closes=""; run_id=""; entry=""; ref=""
while [ $# -gt 0 ]; do
	[ $# -ge 2 ] || die "$cmd: $1 needs a value"
	case "$1" in
		--branch)   branch="$2" ;;
		--tracker)  explicit="$2" ;;
		--identity) identity="$2" ;;
		--closes)   closes="$2" ;;
		--run-id)   run_id="$2" ;;
		--entry)    entry="$2" ;;
		--ref)      ref="$2" ;;
		*) die "$cmd: unknown argument '$1'" ;;
	esac
	shift 2
done

case "$cmd" in
	from-branch)   [ -n "$branch" ] || die "usage: from-branch --branch NAME [--tracker REF]"; from_branch "$branch" "$explicit" ;;
	from-manifest) [ -n "$run_id" ] && [ -n "$entry" ] || die "usage: from-manifest --run-id ID --entry N"; from_manifest "$run_id" "$entry" ;;
	from-history)  [ -n "$ref" ] || die "usage: from-history --ref REF [--tracker REF]"; from_history "$ref" "$explicit" ;;
	remember)      [ -n "$branch" ] && [ -n "$identity" ] || die "usage: remember --branch NAME --identity JSON"; remember "$branch" "$identity" ;;
	pr-reference)  [ -n "$identity" ] && [ -n "$closes" ] || die "usage: pr-reference --identity JSON --closes true|false"; pr_reference "$identity" "$closes" ;;
	*) die "unknown command '${cmd}' (issue-identity: from-branch from-manifest from-history remember pr-reference)" ;;
esac
