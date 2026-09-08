## Summary

<!-- What this branch changes and why, in a few sentences. -->

## Test plans

<!--
One plan per issue this branch resolves — numbered steps a human can follow, ending in an
`Expected:` line. For changes with no user surface, say so and name the command that proves
it instead, e.g. "- no user surface — verify via `scripts/run-tests.sh`".
-->

**#N — <issue title>**

1. …
2. …

Expected: …

## Issues

<!--
`Ready #N` while the issue stays open (a mid-pipeline hop, e.g. into `develop` or `qa`);
`Closes #N` only on the hop into the stage that closes issues.
-->

Ready #N

## Checklist

- [ ] Every commit is **signed** — the pre-push `scripts/checks/verify-git-logs.sh` rejects any
      unpushed commit whose `%G?` isn't `G` or `U`. (Merge commits sometimes sign as `B`;
      re-sign with `git commit --amend --no-edit -S`.)
- [ ] `scripts/run-checks.sh` passes (yamllint + shellcheck + signatures).
- [ ] `scripts/run-tests.sh` passes.
- [ ] User-visible behaviour changes are in the affected plugin's `CHANGELOG.md`
      under `## [Unreleased]`.
