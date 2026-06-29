# lightspeed test rig

A disposable Forgejo instance for exercising the adapters against a real API. **Dev tooling —
not part of the plugin.** Requires `docker` (+ compose) and `jq`.

```bash
./up.sh        # start Forgejo, provision admin/token/repo/labels, write workdir config
./smoke.sh     # run the adapter verbs against the live instance, with assertions
./down.sh      # stop and remove the container, its volume, and the workdir
```

- **Port:** `3000` by default; override with `RIG_PORT=3100 ./up.sh`.
- **Image:** `code.forgejo.org/forgejo/forgejo:15` (pinned to the current major); override with `FORGEJO_IMAGE=…`.
- **Workdir:** `.work/` — a throwaway git repo holding `.lightspeed/config.json` +
  `.lightspeed/secrets.json` pointed at the rig. Gitignored. Drive the adapters by hand from
  there:

  ```bash
  ( cd test-rig/forgejo/.work && ../../../lightspeed/scripts/lightspeed issues list )
  ```

## Not covered

`ci watch` / `ci log` need a registered Actions runner + a workflow to produce runs; the rig
keeps Actions disabled. Exercise those separately when wiring CI.
