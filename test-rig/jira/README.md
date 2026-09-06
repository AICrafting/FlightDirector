# flight Jira test rig

Exercises the **Jira** adapter (an **issues-axis-only** backend) against a **real** Jira Cloud
site. **Dev tooling — not part of the plugin.** Requires `curl` + `jq` and Atlassian
credentials. A live Jira Cloud site can't be containerized like Forgejo, so — like the github
rig — this verifies against the live site.

```bash
cp .env.example .env   # gitignored; fill in FLIGHT_JIRA_SITE / _EMAIL / _TOKEN / _PROJECT
./up.sh        # verify Basic auth + project access, write .work/ config
./smoke.sh     # exercise issues + labels verbs against the live project (marker-tagged), with assertions
./down.sh      # delete only rig-tagged issues; remove .work/
```

- **Auth:** HTTP Basic `email:api_token` (classic Atlassian API token, not OAuth).
- **Workdir:** `.work/` — gitignored; holds `.flightdirector/config.json` + `.flightdirector/secrets.json`
  (`issues.backend=jira`; a throwaway `code` backend since only the issues axis is tested).
- **`.env` resolution:** always read from the **main** repo root, so `up.sh`/`smoke.sh` work when
  run from a linked worktree (where the gitignored `.env` isn't checked out).
- **Markers:** rig issues carry a `[rig]` summary prefix and a `rig` label. `down.sh` deletes only
  those (Jira REST supports issue deletion).
- **Identifiers are keys:** the adapter takes a Jira **key** (`KAN-123`) as the `--number` value.
