# claude-code-keepassxc-skill

A [Claude Code](https://claude.com/claude-code) skill for using secrets from a
local **KeePassXC** database — without the values ever reaching the model's
context, your shell history, or `ps` output.

It is the KeePassXC counterpart to the 1Password skills that already exist: same
idea of `op://`-style secret references and `op run`-style injection, but backed
by a local `.kdbx` file and your desktop keyring instead of a cloud vault.

Ships with `argologin`, a working example of the pattern: logging in to several
ArgoCD instances with admin passwords pulled straight from KeePassXC.

## The idea

An agent should be able to *use* a credential without ever *seeing* it.

```bash
kpsec run -e GITLAB_TOKEN=kp://gitlab/api -- glab api /user   # value only in the child's env
kpsec check kp://gitlab/api                                   # OK  len=26 sha256:1f3a9c02
argologin production                                          # logged in, no password in argv
```

Anything the child process prints that matches a secret is replaced with
`«redacted»` before it reaches the terminal.

## Why not just `keepassxc-cli show`

Three reasons, and they are the whole design:

1. **`keepassxc-cli` prints to stdout.** In an agent session stdout *is* the
   model's context. One `show -a Password` and the secret is in the transcript.
2. **`keepassxc-cli` cannot use your unlocked GUI database.** Every call wants
   the master password again, and an agent's shell has no TTY to type it into.
3. **Passwords passed as CLI flags are world-readable** through
   `/proc/<pid>/cmdline` while the command runs.

So: the master password lives in the desktop keyring (Secret Service), cached in
the kernel keyring with a TTL; values are resolved in-process and handed to the
child through its environment; output is filtered on the way back.

## Install

```bash
git clone https://github.com/jidckii/claude-code-keepassxc-skill.git
cd claude-code-keepassxc-skill
./install.sh          # symlinks skills/keepassxc-secrets into ~/.claude/skills/
kpsec init            # creates ~/Documents/.pass/agents.kdbx, stores the master key
```

`install.sh --copy` copies instead of symlinking. See
[`references/setup.md`](skills/keepassxc-secrets/references/setup.md) for
distribution packages and keyring specifics.

## Secret references

```
kp://<group>/<entry>[#<Attribute>]
```

`Password` is the default attribute. `UserName`, `Title`, `URL` and `Notes` are
treated as public — they are not redacted from output.

```
kp://argocd/production            # the password
kp://argocd/production#UserName   # admin
```

An `.env.tpl` holds references, not values, and is safe to commit:

```
ARGOCD_AUTH_TOKEN=kp://argocd/production
REGISTRY_USER=deployer
REGISTRY_PASSWORD=kp://registry/deployer
```

```bash
kpsec run --env-file=.env.tpl -- docker compose up
```

## Commands

| Command | What it does |
|---|---|
| `kpsec init` | create the database, generate and store the master key |
| `kpsec status` | where the master password comes from, does the database open |
| `kpsec ls [group]` | list entries (never values) |
| `kpsec check <ref>…` | verify a reference resolves — prints length and a sha256 prefix |
| `kpsec run [--env-file=F] [-e VAR=ref] -- cmd` | run a command with secrets in its environment |
| `kpsec add <path> [-u user] [--url u] [-g]` | add or update an entry; the value is typed into a GUI dialog |
| `kpsec clip <ref>` | copy a value to the clipboard for 15 seconds |
| `kpsec lock` | drop the cached master password |
| `kpsec show-master` | show the master password in a GUI dialog (human-only) |

## ArgoCD example

Describe your instances in `~/.config/kpsec/argocd.tsv` (tab-separated, see
[`argocd.tsv.example`](skills/keepassxc-secrets/targets/argocd.tsv.example)):

```
production	argocd.example.com	true	false	true	kp://argocd/production
```

```bash
argologin list                            # aliases and their references
argologin production                      # token written to ~/.config/argocd/config
argocd app list --argocd-context production

argologin production -- argocd app list   # stateless: token in a tmpfs config, deleted after
```

The token is obtained with `POST /api/v1/session` — the password travels in the
request body, never in `argv` — and cached in the kernel keyring for 8 hours.

Aliases marked `protected` refuse mutating verbs (`sync`, `delete`, `rollback`,
`patch`, …) in stateless mode unless `ARGO_ALLOW_WRITE=1` is set. That guard
exists so an agent cannot sync production on its own initiative.

## Security

The full threat model — including what this deliberately does *not* protect
against — is in
[`references/security.md`](skills/keepassxc-secrets/references/security.md).
The short version:

- Agent secrets live in their own `agents.kdbx`, not in your personal database.
- The master password is never written to disk; the cache is kernel memory with
  a TTL.
- Redaction keeps values out of transcripts. It does not stop an agent that is
  allowed to run arbitrary commands from exfiltrating a secret — restrict that
  with Claude Code permission rules, listed in the same document.

## Requirements

`keepassxc-cli` ≥ 2.7, `python3` with `secretstorage` (and `PyYAML` for
`argologin`); optionally `keyutils` for caching, `kdialog`/`zenity` for prompts.
Linux with a Secret Service provider (KDE, GNOME, or any libsecret keyring).

## License

MIT
