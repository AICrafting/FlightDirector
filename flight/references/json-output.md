# Machine-readable output (`--json`)

Flight's default output is for agents: terse, tab-separated and line-oriented (see
[adapter-contract.md](adapter-contract.md) → *Output & exit conventions*). Programs that drive the
dispatcher, such as a desktop app's Issues panel, use the JSON forms described here instead.
They exist so a consumer never has to call a forge or Jira itself, or hold a token.

Ground rules:

- **`--json` is opt-in per call.** Without it, every verb's output stays byte-for-byte what it
  was. Agents and skills keep relying on that.
- **Field names and types are the same on every backend** (Forgejo, GitHub, GitLab, Jira). A
  field the backend can't supply is `null`. It is never left out and never typed differently.
- **Feature-detect, don't version-compare.** Run `flight capabilities --json` and check for the
  token you need. A token is never renamed or removed once released.
- Run `flight` from the repository's working directory, as an agent would.

## Version and capabilities

Neither probe needs a repository, a config, a token or the network.

```
$ flight --version
flight 0.16.0
$ flight --version --json
{"plugin":"flight","version":"0.16.0"}
$ flight capabilities --json
{"plugin":"flight","version":"0.16.0","capabilities":["version","capabilities", …]}
```

`flight capabilities` without `--json` prints one token per line.

| Token | Meaning |
|---|---|
| `version` | `flight --version [--json]` prints the plugin version |
| `capabilities` | this probe |
