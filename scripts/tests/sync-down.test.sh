#!/usr/bin/env bash
# Unit tests for `flight branches sync-down --from <stage>` (flight/scripts/sync-down):
# after a stage-to-stage promotion, merge the target stage back into the source and
# cascade down the pipeline (ADR 0002, #120).
#
# One throwaway sandbox per scenario, no network:
#   * ORIGIN  — a bare repo standing in for the remote;
#   * R       — the "main checkout" the script is anchored to (sits on develop);
#   * P       — a second clone used to perform promotions, so R's refs lag origin
#               exactly the way a real main checkout does after a promote elsewhere.
# The `pr` mode is driven through a stub FLIGHT_SELF (the dispatcher seam): it logs
# `pr open` / `ci watch` / `pr merge`, and its `pr merge` really merges on origin.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SYNC="$REPO_ROOT/flight/scripts/sync-down"
DISPATCH="$REPO_ROOT/flight/scripts/flight"

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail+1)); fi; }

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
ORIGIN="$SANDBOX/origin.git"; R="$SANDBOX/repo"; P="$SANDBOX/promoter"
STUB="$SANDBOX/flight-stub"; STUB_LOG="$SANDBOX/stub.log"

# ── stub dispatcher: pr open / ci watch / pr merge ───────────────────────────
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
# Logs every call as "<group> <verb> <args…>" and answers the three verbs sync-down
# uses in pr mode. `pr merge` performs a real merge on $ORIGIN so the caller's
# post-merge fetch sees what a backend would have written.
set -euo pipefail
printf '%s\n' "$*" >>"${STUB_LOG:?}"
group="$1"; verb="$2"; shift 2
case "$group $verb" in
	"pr open")
		head=""; base=""
		while [ $# -gt 0 ]; do case "$1" in --head) head="$2"; shift 2 ;; --base) base="$2"; shift 2 ;; --body-file) [ -f "$2" ] || { echo "no body file" >&2; exit 1; }; shift 2 ;; *) shift ;; esac; done
		printf '%s\t%s\n' "$head" "$base" >"${STUB_LOG%.log}.pr"
		printf '7\thttps://example.invalid/acme/widget/pulls/7\n' ;;
	"ci watch")
		printf 'ci runs=1 pending=0 failed=%s status=%s\n' "${STUB_CI_FAILED:-0}" "${STUB_CI_STATUS:-success}"
		exit "${STUB_CI_RC:-0}" ;;
	"pr merge")
		IFS=$'\t' read -r head base <"${STUB_LOG%.log}.pr"
		tmp="$(mktemp -d)"
		git clone -q "$ORIGIN" "$tmp"
		git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name t; git -C "$tmp" config commit.gpgsign false
		git -C "$tmp" switch -q "$base"
		git -C "$tmp" merge -q --no-ff -m "Merge PR #7: $head into $base" "origin/$head"
		git -C "$tmp" push -q origin "$base"
		rm -rf "$tmp" ;;
	*) echo "stub: unexpected $group $verb" >&2; exit 2 ;;
esac
EOF
chmod +x "$STUB"
export ORIGIN STUB_LOG

# ── sandbox builders ─────────────────────────────────────────────────────────
gitcfg() { git -C "$1" config user.email t@t; git -C "$1" config user.name t; git -C "$1" config commit.gpgsign false; }

# write_cfg <stages-json-array>
write_cfg() {
	mkdir -p "$R/.flightdirector"
	printf '{"code":{"backend":"forgejo","api":"https://example.invalid/api/v1","owner":"acme","repo":"widget","stages":%s}}\n' "$1" >"$R/.flightdirector/config.json"
}
ALL_DIRECT='[{"name":"develop","merge":"direct"},{"name":"qa","merge":"direct"},{"name":"main","merge":"direct"}]'

# fresh [stages-json] — rebuild origin + R + P with develop/qa/main all at one root commit.
fresh() {
	rm -rf "$ORIGIN" "$R" "$P" "$STUB_LOG" "${STUB_LOG%.log}.pr"
	git init -q --bare -b develop "$ORIGIN"
	git init -q -b develop "$R"; gitcfg "$R"
	git -C "$R" remote add origin "$ORIGIN"
	printf 'root\n' >"$R/base"; git -C "$R" add base; git -C "$R" commit -qm "initial"
	git -C "$R" branch qa develop; git -C "$R" branch main develop
	git -C "$R" push -q -u origin develop qa main
	git -C "$R" branch -q -u origin/qa qa; git -C "$R" branch -q -u origin/main main
	git clone -q "$ORIGIN" "$P"; gitcfg "$P"
	write_cfg "${1:-$ALL_DIRECT}"
}

# commit_on <clone> <branch> <file> <content> — commit and push a change on a branch.
commit_on() {
	git -C "$1" switch -q "$2" 2>/dev/null || git -C "$1" switch -q -c "$2" "origin/$2"
	git -C "$1" pull -q --ff-only origin "$2" 2>/dev/null || true
	printf '%s\n' "$4" >"$1/$3"; git -C "$1" add "$3"; git -C "$1" commit -qm "$2: $3=$4"
	git -C "$1" push -q origin "$2"
}
# promote <lower> <upper> [squash] — merge lower into upper on origin, via clone P.
promote() {
	git -C "$P" fetch -q origin
	git -C "$P" switch -q "$2" 2>/dev/null || git -C "$P" switch -q -c "$2" "origin/$2"
	git -C "$P" reset -q --hard "origin/$2"
	if [ "${3:-}" = squash ]; then
		git -C "$P" merge -q --squash "origin/$1" >/dev/null && git -C "$P" commit -qm "squash: $1 into $2"
	else
		git -C "$P" merge -q --no-ff -m "Merge $1 into $2" "origin/$1"
	fi
	git -C "$P" push -q origin "$2"
}
sha()  { git -C "$R" rev-parse "$1"; }
osha() { git -C "$P" fetch -q origin && git -C "$P" rev-parse "origin/$1"; }

# run [args…] — the script under test, anchored to R, backend calls to the stub.
run() {
	: >"$STUB_LOG"
	FLIGHT_REPO_ROOT="$R" FLIGHT_CONFIG="$R/.flightdirector/config.json" FLIGHT_SELF="$STUB" \
		"$SYNC" "$@" >"$SANDBOX/out" 2>"$SANDBOX/err"
}
out() { cat "$SANDBOX/out"; }
err() { cat "$SANDBOX/err"; }
line() { grep $'^'"$1"$'\t' "$SANDBOX/out" || true; }	# the output row for a stage (plain grep — BusyBox has no -P)

# ── 1. direct, one hop: develop fast-forwards to qa's tip, no new commit ─────
echo "── direct: one hop"
fresh
commit_on "$P" develop f1 one
git -C "$R" pull -q --ff-only origin develop
promote develop qa
before_qa="$(osha qa)"; count_before="$(git -C "$P" rev-list --count "origin/qa")"
run --from qa; rc=$?
check "exit 0" "$([ "$rc" = 0 ] && echo 1 || echo 0)" "$(err)"
check "develop row says fast-forwarded" "$(grep -q $'^develop\tfast-forwarded\t' < <(line develop) && echo 1 || echo 0)" "$(out)"
check "origin/develop == qa tip" "$([ "$(osha develop)" = "$before_qa" ] && echo 1 || echo 0)"
check "local develop (checked out in R) == qa tip" "$([ "$(sha develop)" = "$before_qa" ] && echo 1 || echo 0)"
check "no new commit was created" "$([ "$(git -C "$P" rev-list --count origin/develop)" = "$count_before" ] && echo 1 || echo 0)"
check "no backend call in direct mode" "$([ ! -s "$STUB_LOG" ] && echo 1 || echo 0)"

# --from stages[0] has nothing below it; a non-stage is an error.
run --from develop; rc=$?
check "--from stages[0] → nothing-below, exit 0" "$([ "$rc" = 0 ] && grep -q $'^develop\tnothing-below\t' "$SANDBOX/out" && echo 1 || echo 0)" "$(out) $(err)"
run --from feature/1-x; rc=$?
check "--from a non-stage → non-zero" "$([ "$rc" != 0 ] && grep -q 'not a configured stage' "$SANDBOX/err" && echo 1 || echo 0)" "$(err)"
run; rc=$?
check "missing --from → non-zero usage error" "$([ "$rc" != 0 ] && echo 1 || echo 0)"

# already level: a second run is a no-op
run --from qa; rc=$?
check "re-run when already level → already-level, exit 0" "$([ "$rc" = 0 ] && grep -q $'^develop\talready-level\t' "$SANDBOX/out" && echo 1 || echo 0)" "$(out)"

# ── 2. cascade: qa → main promotion levels qa, then develop ──────────────────
echo "── direct: cascade"
commit_on "$P" develop f2 two
promote develop qa
promote qa main
main_tip="$(osha main)"
run --from main; rc=$?
check "exit 0" "$([ "$rc" = 0 ] && echo 1 || echo 0)" "$(err)"
check "rows in cascade order: qa then develop" "$([ "$(cut -f1 "$SANDBOX/out" | paste -sd, -)" = "qa,develop" ] && echo 1 || echo 0)" "$(out)"
check "origin/qa == main tip" "$([ "$(osha qa)" = "$main_tip" ] && echo 1 || echo 0)"
check "origin/develop == main tip" "$([ "$(osha develop)" = "$main_tip" ] && echo 1 || echo 0)"
check "local qa (not checked out anywhere) was updated too" "$([ "$(sha qa)" = "$main_tip" ] && echo 1 || echo 0)"
check "local develop (checked out) was updated too" "$([ "$(sha develop)" = "$main_tip" ] && echo 1 || echo 0)"

# ── 3. syncDown: none opts qa out and stops the cascade ──────────────────────
echo "── syncDown: none"
fresh '[{"name":"develop","merge":"direct"},{"name":"qa","merge":"direct","syncDown":"none"},{"name":"main","merge":"direct"}]'
commit_on "$P" develop f1 one
promote develop qa; promote qa main
dev_before="$(osha develop)"; qa_before="$(osha qa)"
run --from main; rc=$?
check "exit 0" "$([ "$rc" = 0 ] && echo 1 || echo 0)" "$(err)"
check "qa row says skipped (syncDown: none)" "$(grep -q $'^qa\tskipped\tsyncDown: none' < <(line qa) && echo 1 || echo 0)" "$(out)"
check "cascade stops: no develop row" "$([ -z "$(line develop)" ] && echo 1 || echo 0)" "$(out)"
check "origin/qa untouched" "$([ "$(osha qa)" = "$qa_before" ] && echo 1 || echo 0)"
check "origin/develop untouched" "$([ "$(osha develop)" = "$dev_before" ] && echo 1 || echo 0)"

# ── 4. conflict: aborted, develop unchanged, non-zero ────────────────────────
echo "── direct: conflict"
fresh
commit_on "$P" develop shared from-develop
promote develop qa
commit_on "$P" qa shared fixed-on-qa            # a target-side fix
commit_on "$P" develop shared changed-again     # …and develop moved the same line
git -C "$R" pull -q --ff-only origin develop
dev_before="$(osha develop)"
run --from qa; rc=$?
check "exit non-zero" "$([ "$rc" != 0 ] && echo 1 || echo 0)"
check "develop row says stopped: conflict" "$(grep -q $'^develop\tstopped\tconflict' < <(line develop) && echo 1 || echo 0)" "$(out)"
check "origin/develop unchanged" "$([ "$(osha develop)" = "$dev_before" ] && echo 1 || echo 0)"
check "local develop unchanged" "$([ "$(sha develop)" = "$dev_before" ] && echo 1 || echo 0)"
check "no merge left in progress in the checkout" "$([ ! -e "$R/.git/MERGE_HEAD" ] && echo 1 || echo 0)"
check "checkout tree is clean (tracked files)" "$(git -C "$R" diff --quiet && git -C "$R" diff --cached --quiet && echo 1 || echo 0)"
check "no throwaway worktree left behind" "$([ "$(git -C "$R" worktree list | wc -l)" -eq 1 ] && echo 1 || echo 0)"

# ── 5. squash hop, then sync-down: the next promotion carries only new work ──
echo "── squash hop"
fresh
commit_on "$P" develop a A; commit_on "$P" develop b B
git -C "$R" pull -q --ff-only origin develop
promote develop qa squash
run --from qa; rc=$?
check "exit 0" "$([ "$rc" = 0 ] && echo 1 || echo 0)" "$(err)"
check "develop row says merged (a true merge commit)" "$(grep -q $'^develop\tmerged\t' < <(line develop) && echo 1 || echo 0)" "$(out)"
check "develop and qa now have identical trees" "$([ "$(git -C "$R" rev-parse "develop^{tree}")" = "$(git -C "$R" rev-parse "origin/qa^{tree}")" ] && echo 1 || echo 0)"
check "the merge commit has two parents" "$([ "$(git -C "$R" rev-list --parents -n1 develop | wc -w)" -eq 3 ] && echo 1 || echo 0)"
commit_on "$P" develop c C
git -C "$R" pull -q --ff-only origin develop
check "next hop's diff against qa is only the new file" "$([ "$(git -C "$R" diff --name-only origin/qa develop)" = "c" ] && echo 1 || echo 0)" "$(git -C "$R" diff --name-only origin/qa develop)"
promote develop qa
check "next develop → qa merge is clean and brings only c" "$([ "$(git -C "$P" diff --name-only 'origin/qa~1' origin/qa)" = "c" ] && echo 1 || echo 0)"

# ── 6. pr mode: PR from qa into develop, CI green, auto-merge with `merge` ───
echo "── pr mode"
fresh '[{"name":"develop","merge":"direct","syncDown":"pr"},{"name":"qa","merge":"pr"},{"name":"main","merge":"pr"}]'
commit_on "$P" develop f1 one
git -C "$R" pull -q --ff-only origin develop
promote develop qa
qa_tip="$(osha qa)"
run --from qa; rc=$?
check "exit 0" "$([ "$rc" = 0 ] && echo 1 || echo 0)" "$(err)"
check "pr open called with --head qa --base develop" "$(grep -q '^pr open .*--head qa .*--base develop' "$STUB_LOG" && echo 1 || echo 0)" "$(cat "$STUB_LOG")"
check "ci watch called by --pr" "$(grep -q '^ci watch --pr 7' "$STUB_LOG" && echo 1 || echo 0)"
check "pr merge uses --strategy merge (never the stage's promotion strategy)" "$(grep -q '^pr merge --number 7 --strategy merge$' "$STUB_LOG" && echo 1 || echo 0)" "$(cat "$STUB_LOG")"
check "calls happen in order open → watch → merge" "$([ "$(cut -d' ' -f1,2 "$STUB_LOG" | paste -sd, -)" = "pr open,ci watch,pr merge" ] && echo 1 || echo 0)"
check "develop row says pr-merged #7" "$(grep -q $'^develop\tpr-merged\t#7' < <(line develop) && echo 1 || echo 0)" "$(out)"
check "origin/develop now contains qa" "$(git -C "$P" fetch -q origin && git -C "$P" merge-base --is-ancestor "$qa_tip" origin/develop && echo 1 || echo 0)"
check "local develop (checked out, clean) fast-forwarded to the merged tip" "$([ "$(sha develop)" = "$(osha develop)" ] && echo 1 || echo 0)"
# the default mode is the stage's own merge value: qa is merge:pr with no syncDown → pr
commit_on "$P" develop f2 two
git -C "$R" pull -q --ff-only origin develop
promote develop qa; promote qa main
run --from main; rc=$?
check "qa (merge: pr, no syncDown) defaults to pr mode" "$(grep -q '^pr open .*--head main .*--base qa' "$STUB_LOG" && echo 1 || echo 0)" "$(cat "$STUB_LOG")"
check "cascade continues into develop by PR" "$(grep -q '^pr open .*--head qa .*--base develop' "$STUB_LOG" && echo 1 || echo 0)" "$(cat "$STUB_LOG")"
check "everything level after the cascade" "$([ "$(osha develop)" != "" ] && git -C "$P" merge-base --is-ancestor origin/main origin/qa && git -C "$P" merge-base --is-ancestor origin/qa origin/develop && echo 1 || echo 0)"

# ── 7. pr mode: red CI leaves the PR open and stops ──────────────────────────
echo "── pr mode: red CI / timeout"
fresh '[{"name":"develop","merge":"direct","syncDown":"pr"},{"name":"qa","merge":"pr"},{"name":"main","merge":"pr"}]'
commit_on "$P" develop f1 one
git -C "$R" pull -q --ff-only origin develop
promote develop qa
dev_before="$(osha develop)"
STUB_CI_STATUS=failure STUB_CI_FAILED=1 run --from qa; rc=$?
check "red CI → exit non-zero" "$([ "$rc" != 0 ] && echo 1 || echo 0)"
check "row says stopped, names the open PR and the CI status" "$(grep -q $'^develop\tstopped\tPR #7 left open.*failure' < <(line develop) && echo 1 || echo 0)" "$(out)"
check "pr merge was NOT called" "$(grep -q '^pr merge' "$STUB_LOG" && echo 0 || echo 1)"
check "origin/develop untouched" "$([ "$(osha develop)" = "$dev_before" ] && echo 1 || echo 0)"
STUB_CI_RC=1 run --from qa; rc=$?
check "ci watch timeout (non-zero) → stopped, PR left open" "$([ "$rc" != 0 ] && grep -q $'^develop\tstopped\tPR #7 left open' < <(line develop) && ! grep -q '^pr merge' "$STUB_LOG" && echo 1 || echo 0)" "$(out)"

# ── 8. dirty checkout: merge in a throwaway worktree, push, report behind ────
echo "── direct: dirty checkout"
fresh
commit_on "$P" develop f1 one
git -C "$R" pull -q --ff-only origin develop
promote develop qa
qa_tip="$(osha qa)"; dev_local="$(sha develop)"
printf 'uncommitted\n' >"$R/base"          # tracked file modified in the main checkout
run --from qa; rc=$?
check "exit 0" "$([ "$rc" = 0 ] && echo 1 || echo 0)" "$(err)"
check "origin/develop == qa tip" "$([ "$(osha develop)" = "$qa_tip" ] && echo 1 || echo 0)"
check "row reports the local checkout is behind" "$(grep -q 'local checkout .* is behind' < <(line develop) && echo 1 || echo 0)" "$(out)"
check "local develop ref was not moved under the dirty checkout" "$([ "$(sha develop)" = "$dev_local" ] && echo 1 || echo 0)"
check "the uncommitted edit is intact" "$([ "$(cat "$R/base")" = "uncommitted" ] && echo 1 || echo 0)"
check "throwaway worktree removed" "$([ "$(git -C "$R" worktree list | wc -l)" -eq 1 ] && echo 1 || echo 0)"
git -C "$R" checkout -q -- base

# ── 9. ahead / diverged lower stage → STOP, nothing pushed ───────────────────
echo "── freshness: ahead / diverged"
fresh
commit_on "$P" develop f1 one
git -C "$R" pull -q --ff-only origin develop
promote develop qa
printf 'local-only\n' >"$R/local"; git -C "$R" add local; git -C "$R" commit -qm "unpushed on develop"
dev_origin="$(osha develop)"; dev_local="$(sha develop)"
run --from qa; rc=$?
check "ahead → exit non-zero" "$([ "$rc" != 0 ] && echo 1 || echo 0)"
check "row says stopped: local develop is ahead of origin/develop" "$(grep -q $'^develop\tstopped\t.*ahead of origin/develop' < <(line develop) && echo 1 || echo 0)" "$(out)"
check "origin/develop untouched" "$([ "$(osha develop)" = "$dev_origin" ] && echo 1 || echo 0)"
check "local develop untouched" "$([ "$(sha develop)" = "$dev_local" ] && echo 1 || echo 0)"
commit_on "$P" develop other x            # now origin moved too → diverged
run --from qa; rc=$?
check "diverged → exit non-zero, says diverged" "$([ "$rc" != 0 ] && grep -q 'diverged' < <(line develop) && echo 1 || echo 0)" "$(out)"

# behind (not checked out): the local ref is fast-forwarded before the merge
fresh
commit_on "$P" develop f1 one
promote develop qa; promote qa main
commit_on "$P" qa hot fix                  # qa moved on origin; R's local qa is behind
git -C "$R" pull -q --ff-only origin develop
run --from main; rc=$?
check "behind lower stage is fast-forwarded first, then merged (main → qa is a real merge)" "$([ "$rc" = 0 ] && grep -q $'^qa\tmerged\t' < <(line qa) && echo 1 || echo 0)" "$(out) $(err)"
check "origin/qa contains both main and the hotfix" "$(git -C "$P" fetch -q origin && git -C "$P" merge-base --is-ancestor origin/main origin/qa && git -C "$P" diff --quiet origin/qa origin/qa -- && [ "$(git -C "$P" show origin/qa:hot)" = fix ] && echo 1 || echo 0)"
check "develop then fast-forwards to the new qa" "$([ "$(osha develop)" = "$(osha qa)" ] && echo 1 || echo 0)"

# ── 10. bad config values ────────────────────────────────────────────────────
echo "── config validation"
fresh '[{"name":"develop","merge":"direct","syncDown":"rebase"},{"name":"qa","merge":"direct"}]'
commit_on "$P" develop f1 one; promote develop qa
run --from qa; rc=$?
check "invalid syncDown value → non-zero, named" "$([ "$rc" != 0 ] && grep -q "syncDown" "$SANDBOX/err" && echo 1 || echo 0)" "$(err)"

# ── 11. through the dispatcher ───────────────────────────────────────────────
echo "── dispatcher routing"
fresh
commit_on "$P" develop f1 one
git -C "$R" pull -q --ff-only origin develop
promote develop qa
out="$(cd "$R" && "$DISPATCH" branches sync-down --from qa 2>"$SANDBOX/err")"; rc=$?
check "flight branches sync-down --from qa routes to the script" "$([ "$rc" = 0 ] && grep -q $'^develop\tfast-forwarded' <<<"$out" && echo 1 || echo 0)" "$out $(err)"
out="$(cd "$R" && "$DISPATCH" branches bogus 2>&1)"; rc=$?
check "unknown branches verb lists sync-down in the usage" "$([ "$rc" != 0 ] && grep -q 'sync-down' <<<"$out" && echo 1 || echo 0)" "$out"

# Summary: plain when nothing failed, red when something did (#123).
[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
