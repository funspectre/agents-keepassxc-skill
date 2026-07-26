# agents-keepassxc-skill

*English · [Русский](README.ru.md)*

An [Agent Skill](https://agents.md) for using secrets from a local **KeePassXC**
database — without the values ever reaching the model's context, your shell
history, or `ps` output.

Written in the portable `SKILL.md` format, so the same directory works in Claude
Code, Codex CLI, Cursor, Gemini CLI and any other harness that reads skills;
harnesses that only read `AGENTS.md` are covered by a pointer block the installer
writes. See [Install](#install).

It is the KeePassXC counterpart to the 1Password skills that already exist: same
idea of `op://`-style secret references and `op run`-style injection, but backed
by a local `.kdbx` file and your desktop keyring instead of a cloud vault.

## The idea

An agent should be able to *use* a credential without ever *seeing* it.

```bash
kpsec run -e GITLAB_TOKEN=kp://gitlab/api -- glab api /user   # value only in the child's env
kpsec check kp://gitlab/api                                   # OK  len=26 sha256:1f3a9c02
```

No command here prints a secret: values are resolved inside `kpsec` and reach the
child through its environment, never through stdout or argv. `kpsec` is a shell
script (PowerShell on Windows) — no language runtime to install.

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
git clone https://github.com/jidckii/agents-keepassxc-skill.git
cd agents-keepassxc-skill
./install.sh --bin    # every detected harness, plus kpsec on PATH
kpsec init            # creates ~/.pass/agents.kdbx, stores the master key
```

On Windows use `.\install.ps1` (same flags in PowerShell style: `-Project`,
`-AllUser`, `-Copy`, `-List`).

`install.sh` symlinks the skill directory, so `git pull` updates every harness at
once (`--copy` if you would rather have independent copies). It is idempotent —
re-run it after adding a new harness.

| Where | Harnesses | How |
|---|---|---|
| `~/.claude/skills/` | Claude Code | `./install.sh` (auto-detected) |
| `~/.codex/skills/` | Codex CLI | `./install.sh` (auto-detected) |
| `~/.gemini/skills/` | Gemini CLI, Antigravity | `./install.sh` (auto-detected) |
| `<project>/.cursor/skills/` | Cursor — it has no personal skills directory | `./install.sh --project` |
| `<project>/.agents/skills/` | Cline, Amp, opencode, Antigravity | `./install.sh --project` |
| `<project>/AGENTS.md` | Copilot, Windsurf, Aider, Zed, Devin, Jules, … | `./install.sh --project` |
| anywhere else | any harness with a skills directory | `./install.sh --skills-dir PATH` |

`./install.sh --list` prints the paths and what was detected. `--all-user`
installs for every known harness even if it is not installed yet.

For AGENTS.md-only harnesses the installer appends a short pointer block between
`<!-- keepassxc-secrets:begin -->` markers — re-running replaces that block and
leaves the rest of the file alone.

See [`references/setup.md`](skills/keepassxc-secrets/references/setup.md) for
distribution packages and keyring specifics.

## Secret references

```
kp://<group>/<entry>[#<Attribute>]
```

`Password` is the default attribute; `UserName`, `Title`, `URL` and `Notes` work
the same way.

```
kp://gitlab/api            # the password
kp://gitlab/api#UserName   # alice
```

An `.env.tpl` holds references, not values, and is safe to commit:

```
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
| `kpsec relocate <path>` | re-point the stored master key after moving the `.kdbx` file |
| `kpsec show-master` | show the master password in a GUI dialog (human-only) |

## Building your own tools on it

`kpsec` doubles as a library. Sourced with `KPSEC_LIB=1` it skips the command
dispatch and exposes its functions, so your wrapper resolves a secret without it
passing through an intermediate stdout:

```bash
KPSEC_LIB=1 . "$HOME/.claude/skills/keepassxc-secrets/scripts/kpsec"

token=$(resolve "kp://gitlab/api")     # stays in this shell's memory
export GITLAB_TOKEN="$token"           # export, not `env VAR=… cmd` — argv is public
exec glab api /user
```

Useful entry points: `resolve` / `resolve_soft`, `kp` (runs `keepassxc-cli` with
the master password on stdin), `master_get`, and the cache helpers
`cache_get` / `cache_put` / `cache_drop` for derived credentials such as session
tokens. The ArgoCD login helper in the author's dotfiles is built exactly this
way.

## Security

The full threat model — including what this deliberately does *not* protect
against — is in
[`references/security.md`](skills/keepassxc-secrets/references/security.md).
The short version:

- Agent secrets live in their own `agents.kdbx`, not in your personal database.
- The master password is never written to disk; the cache is kernel memory with
  a TTL.
- `kpsec run` execs the command without touching its output, so a tool that
  prints its own credentials still leaks them. That is a deliberate trade —
  see the same document.
- Nothing here stops an agent that is allowed to run arbitrary commands from
  exfiltrating a resolved secret — restrict that with your harness's permission
  rules; ready-made ones are in the same document.

## Platforms

`keepassxc-cli` ≥ 2.7 and a shell. What differs is where the master key lives and
how you get asked for it:

| | Master key store | Prompt | Extra |
|---|---|---|---|
| Linux, KDE/GNOME | Secret Service via `secret-tool`, unlocked at login by PAM | kdialog / zenity | `keyutils` for the TTL cache |
| Linux, Hyprland/Sway/i3 | KeePassXC's own Secret Service, or standalone gnome-keyring | pinentry (Qt/GTK/curses) | see [`platforms.md`](skills/keepassxc-secrets/references/platforms.md) |
| macOS | login Keychain via `security` | osascript dialog | CLI lives inside the app bundle |
| Windows | Credential Manager via the native API | `Get-Credential` dialog | `kpsec.ps1`, installed by `install.ps1` |

`kpsec status` prints which backend is actually in use; `KPSEC_KEYRING` pins one.
On a minimal Linux session the `org.freedesktop.secrets` slot is usually free,
which is the one case where KeePassXC's own Secret Service integration is the
simplest answer — details and PAM snippets in
[`references/platforms.md`](skills/keepassxc-secrets/references/platforms.md).

## Acknowledgements

The reference-and-inject approach comes from the 1Password side of this problem,
in particular [kcmadden/claude-code-1password-skill](https://github.com/kcmadden/claude-code-1password-skill)
— `op://` references, `op run` for injection, and the rule of committing
templates rather than values. This project keeps those ideas and swaps the cloud
vault for a local `.kdbx` plus the desktop keyring, which is what makes the
unlock problem (and most of the design here) different.

## License

MIT
