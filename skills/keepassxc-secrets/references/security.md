# Threat model and design decisions

## What this protects against

**Secrets ending up in the model context.** Anything an agent's shell prints is
read by the model and may be persisted in a transcript. Every path here keeps
values out of stdout: they are resolved inside `kpsec` and passed to the child
through its environment. No command in this skill prints a secret.

**Secrets ending up in process arguments.** `/proc/<pid>/cmdline` is world
readable on a default Linux install. Any `tool --password X` exposes the password
to every process on the machine for the duration of the call. Nothing here passes
a secret as an argument — values go through the environment of the child process,
and wrappers built on `kpsec_core` should prefer an API call with the credential
in the request body over a CLI flag.

**Secrets ending up on disk.** The master password is never written to a file,
and the cache lives in kernel memory with a TTL.

**Blast radius of the main database.** Agents get their own `agents.kdbx`. A
mistake or a prompt injection can only reach the secrets deliberately copied
there, not a lifetime of personal credentials.

## What this does NOT protect against

- **A malicious local process running as your user.** It can read the kernel
  keyring and query the Secret Service just as these scripts do. On a desktop
  where the keyring auto-unlocks at login, "unlocked" means unlocked for
  everything running as you.
- **A child process that prints its own credentials.** `kpsec run` execs the
  command and does not touch its output, so a tool with verbose HTTP logging or a
  debug mode can put the secret in the transcript itself. Filtering was
  deliberately dropped: doing it reliably means keeping the child's stdout in a
  pipe, which breaks interactive tools and progress output, and it protects
  against carelessness rather than against an attacker. Know your commands.
- **An agent that runs an arbitrary command with a resolved secret.** If the
  agent can call `kpsec run`, it can pass the secret to a program of its
  choosing. Constrain that with permission rules, not with this skill.
- **Secrets already leaked elsewhere** — CI variables, dotfiles, shell history
  from before the migration.

## Why not the Secret Service directly

KeePassXC can register as the `org.freedesktop.secrets` provider, which would let
`secret-tool` read entries from the already-unlocked GUI database. In practice
that slot is often taken: on KDE Plasma `ksecretd` owns it, on GNOME
`gnome-keyring-daemon` does, and KeePassXC then refuses to register
("another secret service is running").

So the design goes the other way round: the desktop keyring holds one secret —
the master password of `agents.kdbx` — and `keepassxc-cli` does the rest. That
works on any desktop, with any keyring, without reconfiguring the session.

## Why the kernel keyring for caching

`keyctl` keys live in kernel memory, are scoped to the user session, never touch
disk, and expire on their own via `keyctl timeout`. Compared to a file in
`/dev/shm` or an environment variable in a long-lived shell, that is both simpler
and harder to leak by accident. If `keyctl` is missing, everything still works —
the scripts fall back to the Secret Service on each call.

## Recommended permission rules

Whatever the harness, the shape is the same: allow `kpsec`, deny everything that
reads the database or the keyring directly. Denying `keepassxc-cli` is the
important half — it removes the obvious way to print a password. `kpsec` invokes
that binary itself, so the deny rule (which applies to the agent's own shell
commands) does not get in its way.

**Claude Code** — `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(~/.claude/skills/keepassxc-secrets/scripts/kpsec:*)"
    ],
    "deny": [
      "Bash(keepassxc-cli:*)",
      "Bash(keyctl:*)",
      "Read(//home/*/.pass/**)"
    ]
  }
}
```

**Codex CLI** — approval and sandbox policy live in `~/.codex/config.toml`; there
is no per-command allowlist, so the equivalent is to run with approvals on for
commands outside the sandbox and rely on the instruction in `SKILL.md`.

**Cursor, Copilot, Windsurf and other IDE agents** — command allowlists/denylists
sit in the tool's own settings UI. Add `keepassxc-cli` to the denylist and
`kpsec` to the allowlist.

**Any harness** — a filesystem-level backstop that does not depend on the agent
honouring anything: keep the database outside the workspace (`~/.pass`, not the
repo) so a project-scoped agent cannot read the `.kdbx` at all.
