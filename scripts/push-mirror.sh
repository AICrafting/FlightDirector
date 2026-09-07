#!/usr/bin/env bash
# Publish a branch and the release tags at its head to the public mirror.
#
#   scripts/push-mirror.sh [--remote <name>] [--branch <name>]... [--dry-run]
#
# Defaults: --remote github, --branch main. For each branch it:
#   1. fetches origin/<branch> (the source of truth) and the mirror's copy;
#   2. pushes origin/<branch> to the mirror FAST-FORWARD ONLY — if the mirror's
#      branch is not an ancestor of ours, something changed on the mirror out of
#      band; the script refuses and never forces (fix the mirror by hand);
#   3. pushes every tag that points at that head (git tag --points-at), so a
#      release branch and its `<plugin>-<version>` tag always move together.
#
# --dry-run prints the plan and touches nothing. Run it after a terminal-stage
# promotion (and after scripts/tag-release.sh), or any time the mirror lags.
# Repo tooling for Flight Director's own mirror; not shipped in the plugin.
set -euo pipefail

REPO_ROOT="${PUSH_MIRROR_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
die() { printf '\033[0;31mpush-mirror: %s\033[0m\n' "$1" >&2; exit 1; }
say() { printf '\033[0;32mpush-mirror:\033[0m %s\n' "$1"; }

REMOTE="github"; BRANCHES=(); DRY=0
while [ $# -gt 0 ]; do
	case "$1" in
		--remote)  [ $# -ge 2 ] || die "missing value for $1"; REMOTE="$2"; shift 2 ;;
		--branch)  [ $# -ge 2 ] || die "missing value for $1"; BRANCHES+=("$2"); shift 2 ;;
		--dry-run) DRY=1; shift ;;
		*) die "unknown argument: $1 (usage: push-mirror.sh [--remote <name>] [--branch <name>]... [--dry-run])" ;;
	esac
done
[ ${#BRANCHES[@]} -gt 0 ] || BRANCHES=(main)

git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1 || die "no 'origin' remote"
git -C "$REPO_ROOT" remote get-url "$REMOTE" >/dev/null 2>&1 || die "no '$REMOTE' remote — add the mirror first (git remote add $REMOTE <url>)"

# Fetch each requested branch on its own so one unknown name doesn't abort the
# rest — the loop below reports it as skipped and exits non-zero at the end.
for branch in "${BRANCHES[@]}"; do
	git -C "$REPO_ROOT" fetch -q origin "$branch" 2>/dev/null || true
done
git -C "$REPO_ROOT" fetch -q --tags origin || die "cannot fetch tags from origin"
git -C "$REPO_ROOT" fetch -q "$REMOTE" 2>/dev/null || true	# the mirror may lack some branches yet

status=0
for branch in "${BRANCHES[@]}"; do
	src="$(git -C "$REPO_ROOT" rev-parse --verify -q "refs/remotes/origin/$branch")" || { printf 'push-mirror: origin has no branch %s — skipping\n' "$branch" >&2; status=1; continue; }
	short="${src:0:7}"
	mirror="$(git -C "$REPO_ROOT" rev-parse --verify -q "refs/remotes/$REMOTE/$branch" 2>/dev/null || true)"

	# Tags at this head — release tags ride along with the branch they belong to.
	mapfile -t tags < <(git -C "$REPO_ROOT" tag --points-at "$src")

	if [ -n "$mirror" ] && [ "$mirror" = "$src" ]; then
		say "$REMOTE/$branch already at $short"
	elif [ -n "$mirror" ] && ! git -C "$REPO_ROOT" merge-base --is-ancestor "$mirror" "$src"; then
		printf '\033[0;31mpush-mirror: %s/%s (%s) is not an ancestor of origin/%s (%s) — the mirror moved out of band; refusing to force-push. Reconcile by hand.\033[0m\n' \
			"$REMOTE" "$branch" "${mirror:0:7}" "$branch" "$short" >&2
		status=1
		continue
	else
		behind="$([ -n "$mirror" ] && git -C "$REPO_ROOT" rev-list --count "$mirror..$src" || echo "all")"
		if [ "$DRY" = 1 ]; then
			say "[dry-run] would push origin/$branch ($short) → $REMOTE/$branch (fast-forward, $behind new commit(s))"
		else
			git -C "$REPO_ROOT" push "$REMOTE" "$src:refs/heads/$branch" || { status=1; continue; }
			say "pushed origin/$branch ($short) → $REMOTE/$branch ($behind new commit(s))"
		fi
	fi

	for tag in "${tags[@]}"; do
		if git -C "$REPO_ROOT" ls-remote --exit-code --tags "$REMOTE" "refs/tags/$tag" >/dev/null 2>&1; then
			say "tag $tag already on $REMOTE"
		elif [ "$DRY" = 1 ]; then
			say "[dry-run] would push tag $tag (at $short) → $REMOTE"
		else
			git -C "$REPO_ROOT" push "$REMOTE" "refs/tags/$tag" || { status=1; continue; }
			say "pushed tag $tag → $REMOTE"
		fi
	done
	[ ${#tags[@]} -gt 0 ] || say "no tags at $short"
done
exit "$status"
