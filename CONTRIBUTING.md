# Contributing

Thanks for helping improve chi-server. Bug reports, documentation fixes and new stacks are all welcome.

## Ground rules

- **English only** in code, comments, messages and docs.
- **Idempotent scripts.** Every command must be safe to run again. Check state before changing it, and skip steps
  that are already done.
- **No logic hidden in docs.** If a step can be scripted, script it; document only what must be done by hand.
- **No secrets or personal data** in commits: no real hostnames, tailnet names, IPs, tokens or topics. Use
  placeholders such as `<you>`, `example.com`, `your-tailnet.ts.net`.
- **Backward compatibility.** Live servers depend on `.env` keys, CLI subcommands, file paths, launchd labels
  (`com.chi-service.*`) and the log directory (`~/Library/Logs/chi-service`). Do not rename them without a
  migration.

## Shell style

Scripts run on the `/bin/bash` that ships with macOS: **bash 3.2**.

- No associative arrays, no `mapfile`/`readarray`, no `${var,,}` / `${var^^}`, no `"${a[@]}"` on arrays that may be
  empty under `set -u`.
- Start executables with `#!/usr/bin/env bash` and `set -euo pipefail` (read-only checkers like `doctor.sh` use
  `set -uo pipefail` and count failures).
- Source `scripts/lib.sh` and use its helpers: `log`, `ok`, `warn`, `die`, `load_env`, `set_kv`, `get_kv`,
  `render_tmpl`, `stack_conf`, `compose`, `sudo_ts`.
- Brace variables inside strings (`"${name}:"`), quote expansions, prefer `[ ]` and `case`.
- Messages are short and imperative and say what to do next (`-> chi up media`).
- Comments explain **why**, not what.
- Avoid GNU/BSD differences (for example `sed -i`); `set_kv` writes through a temp file for that reason.

## Checks

Run before opening a pull request:

```bash
shellcheck -x bin/chi scripts/*.sh stacks/*/*.sh
for f in bin/chi scripts/*.sh stacks/*/*.sh; do bash -n "$f"; done
bats tests/
```

CI (`.github/workflows/lint.yml`) runs shellcheck and `docker compose config` for every stack. To validate compose
files locally:

```bash
cp .env.example /tmp/chi-ci.env
sed -i '' "s#/Users/CHANGE_ME#$HOME#g; s#^TS_FQDN=#TS_FQDN=ci.example.ts.net#" /tmp/chi-ci.env
for f in stacks/*/compose.yaml; do
  s="$(basename "$(dirname "$f")")"
  docker compose -p "chi-$s" --env-file /tmp/chi-ci.env -f "$f" config -q && echo "ok $s"
done
```

## Tests

Tests use [bats-core](https://github.com/bats-core/bats-core) and live in `tests/` (`brew install bats-core`). Add
tests for pure helpers and parsing logic (`lib.sh` functions, manifest parsing, template rendering). Tests must
not need Docker, Tailscale, sudo or network access.

## Adding a stack

Follow [docs/adding-a-stack.md](docs/adding-a-stack.md). A new stack needs a `compose.yaml` (or `fetch.sh`), a
`stack.conf`, a Homepage entry and a page under `docs/modules/`.

## Pull requests

- One topic per pull request; describe what changed and how you tested it (on a real Mac if it touches macOS
  settings).
- Update the docs and `CHANGELOG.md` (under "Unreleased") in the same pull request.
- Keep commits focused, with messages in the imperative mood.

## Reporting security issues

Do not open public issues for vulnerabilities. See [SECURITY.md](SECURITY.md).
