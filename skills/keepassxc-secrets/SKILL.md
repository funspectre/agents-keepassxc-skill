---
name: keepassxc-secrets
description: Use when a command needs a password, token or API key that lives in a local KeePassXC database — resolve it into the command's environment without ever printing the value. Covers kp:// secret references and kpsec run/check/ls/add.
requires:
  bins: ["keepassxc-cli"]
---

# keepassxc-secrets — secrets from KeePassXC without leaking them

Agent-facing secrets live in a **separate database**, by default `~/.pass/agents.kdbx`.
Its master password is stored in the system keyring (Secret Service on Linux,
Keychain on macOS, Credential Manager on Windows) and, on Linux, cached in the
kernel keyring, so the commands run without prompting. The user's main database
stays out of reach — that is what bounds the blast radius.

`kpsec` is a shell script (`kpsec.ps1` on Windows). No runtime beyond the shell.

## The one rule

**Never print a secret and never call `keepassxc-cli` directly.** Its output goes
straight into the transcript. `kpsec` resolves values inside its own process and
hands them to the child through the environment — they never touch stdout or argv.

Never:

```bash
keepassxc-cli show ... -a Password         # the value lands in the model context
some-cli --password "$(...)"               # the password is visible in /proc/*/cmdline
export TOKEN=$(...)                        # the value sticks in history and logs
```

Instead:

```bash
kpsec run -e TOKEN=kp://gitlab/api -- some-cli   # secret only in the child's env
kpsec check kp://gitlab/api                      # verify without revealing
```

`kpsec run` does not filter what the child prints. If a command is known to echo
its credentials (debug output, verbose HTTP logs), do not run it under `kpsec run`
in an agent session.

## Reference format

```
kp://<group>/<entry>[#<Attribute>]
```

The default attribute is `Password`.

## Commands

```bash
kpsec status                              # database, keyring backend, unlock check
kpsec ls                                  # entries, without values
kpsec check kp://gitlab/api               # OK + length and a local fingerprint
kpsec run -e TOKEN=kp://gitlab/api -- glab api /user
kpsec run --env-file .env.tpl -- docker compose up
kpsec add gitlab/api -u alice             # value typed by a human in a GUI dialog
kpsec add gitlab/api -g -L 32             # generate a random value
kpsec clip kp://gitlab/api                # clipboard for 15 seconds
kpsec lock                                # drop the cached master password
```

`.env.tpl` is a plain env file whose values are either literals or `kp://`
references. It is safe to commit — it holds no values:

```
REGISTRY_USER=deployer
REGISTRY_PASSWORD=kp://registry/deployer
```

Commands an agent must **not** run: `kpsec add --stdin` (it reads the value from
stdin, so the agent would have to be holding the plaintext to use it),
`kpsec show-master` and `kpsec clip` (the clipboard reads back with `pbpaste`).
Those are for the human at the keyboard.

`kpsec check` prints a fingerprint, not a hash of the value: it is salted with a
local file, so it identifies a value on this machine and means nothing off it.

## Adding a secret

```bash
kpsec add <group>/<entry> -u <username> --url <url>
```

The value is typed into a GUI dialog, so it never passes through the agent's
command line. Verify with `kpsec check kp://<group>/<entry>`.

`keepassxc-cli` cannot set or filter by tags, so entries are organised by group
(`argocd/…`, `gitlab/…`, `registry/…`) and the reference mirrors that path.

## Building tools on top

`kpsec` doubles as a library. Sourcing it with `KPSEC_LIB=1` skips the command
dispatch and exposes `resolve`, `kp`, `master_get` and the keyring helpers, so a
wrapper can resolve a secret without it passing through an intermediate stdout.

This is for wrappers a human writes and reviews, **not** for an agent to
assemble on the fly: the plaintext sits in a shell variable, one `echo` away
from the transcript, which is exactly what the rule above exists to prevent.

```bash
KPSEC_LIB=1 . "$HOME/.claude/skills/keepassxc-secrets/scripts/kpsec"

token=$(resolve "kp://gitlab/api")     # stays in this shell's memory
export GITLAB_TOKEN="$token"           # export, not `env VAR=… cmd` — argv is public
exec glab api /user
```

## Troubleshooting

- `kpsec status` shows the keyring backend in use, the resolved `keepassxc-cli`
  and whether the database opens.
- `unlock: FAILED` — the stored key does not match the database. After moving the
  `.kdbx`, re-point the key with `kpsec relocate <new-path>`.
- Prompts need a graphical session; without one they are skipped rather than
  blocking. For headless runs set `KPSEC_NO_GUI=1` — the commands then fail with
  exit code 4 rather than waiting on a dialog. Supply the master password with
  `KPSEC_MASTER_COMMAND` instead.
- `init` and `show-master` print the master password to `/dev/tty`, never to
  stdout and never to a dialog. `KPSEC_NO_GUI` does not suppress that: with no
  terminal either they exit 6 and `init` creates nothing, but a terminal is a
  terminal, so **anything recording one — `script`, tmux logging, an agent
  harness that allocates a pty — records the password.** Both commands are for
  a human at a real terminal.
- Environment: `KPSEC_DB`, `KPSEC_TTL`, `KPSEC_CONFIG`, `KPSEC_KEYRING`
  (`secretservice` / `keychain` / `none`), `KPSEC_KEEPASSXC_CLI`,
  `KPSEC_MASTER_COMMAND`, `KPSEC_PROMPT_TIMEOUT`. The config file accepts all of
  these except `KPSEC_MASTER_COMMAND` and `KPSEC_KEEPASSXC_CLI`, which are
  environment-only because both end up in front of an interpreter.
- See `references/security.md` for the threat model, `references/setup.md` for
  installation and `references/platforms.md` for Linux/macOS/Windows specifics.
