# Threat model and design decisions

## What this protects against

**Secrets ending up in the model context.** Anything an agent's shell prints is
read by the model and may be persisted in a transcript. Every path here keeps
values out of stdout: they are resolved inside `kpsec` and passed to the child
through its environment. No command prints a resolved secret, and the two that
print the master password — `init` and `show-master` — write it to `/dev/tty`,
which a pipe does not capture but a recorded terminal does. Both are for a human
at a terminal, not for an agent.

**Secrets ending up in process arguments.** `/proc/<pid>/cmdline` is world
readable on a default Linux install, and `ps` shows the arguments of anything
running as you on macOS. Any `tool --password X` exposes the password for the
duration of the call. Nothing here passes a secret as an argument: the master
password reaches `keepassxc-cli`, `secret-tool` and `security` on stdin, it is
never handed to a dialog (which would take it as an argument — see `reveal` in
the script), and resolved values go
through the environment of the child process. Wrappers that source `kpsec`
should prefer an API call with the credential in the request body over a CLI
flag.

**Secrets ending up on disk.** The master password is never written to a file,
and the cache lives in kernel memory with a TTL. The one file `kpsec` does
write is the fingerprint salt (`fingerprint-salt`, 0600, next to the config),
which is random and not derived from any secret.

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
  choosing — including one that prints it. `kpsec run -- <anything>` is
  arbitrary command execution, so an allow rule covering it is an allow rule
  covering everything. Constrain that with permission rules, not with this
  skill, and read the next section before writing one.
- **An agent that can run shell commands at all.** The master password sits in
  a keyring that unlocks with the session, so anything running as you can read
  it out and open the database directly — `kpsec` is a convention that keeps
  secrets out of a transcript by default, not a sandbox that keeps them away
  from a determined caller. The database boundary is what bounds the damage:
  put only what the agent genuinely needs in `agents.kdbx`.
- **`kpsec clip`.** The value goes to the session clipboard, where `pbpaste`,
  `wl-paste` or `xclip -o` will read it back. It is a convenience for the human
  at the keyboard, not a way to hand a secret to an agent.
- **Wrappers that source `kpsec`.** Library mode puts the plaintext in a shell
  variable, one `echo` away from the transcript, and `resolve` returns a status
  rather than aborting — an unchecked wrapper runs its command with an empty
  credential. Write those by hand for a specific job; they are not something an
  agent should be generating on the fly.
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

Whatever the harness, the shape is the same: allow the subcommands that cannot
reveal a value, and leave the ones that can to a prompt.

**Do not allow `kpsec` as a prefix.** A rule like
`Bash(…/scripts/kpsec:*)` matches `kpsec run -- <anything>`, so it does not
just permit this skill — it permits every command on the machine, past every
other rule in the file. Allow the read-only subcommands instead:

**Claude Code** — `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(~/.claude/skills/keepassxc-secrets/scripts/kpsec status)",
      "Bash(~/.claude/skills/keepassxc-secrets/scripts/kpsec ls:*)",
      "Bash(~/.claude/skills/keepassxc-secrets/scripts/kpsec check:*)"
    ],
    "deny": [
      "Bash(keepassxc-cli:*)",
      "Bash(/usr/bin/keepassxc-cli:*)",
      "Bash(/opt/homebrew/bin/keepassxc-cli:*)",
      "Bash(/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli:*)",
      "Bash(keyctl:*)",
      "Bash(secret-tool:*)",
      "Bash(security:*)",
      "Read(//home/*/.pass/**)",
      "Read(//Users/*/.pass/**)"
    ]
  }
}
```

`kpsec run` is deliberately not in the allow list: approving it is approving
the command it wraps, which is a decision per call.

Two things these rules do not do. A deny list matched on command prefixes is
not a boundary — `sh -c 'keepassxc-cli …'`, another copy of the binary or a
path spelled differently all get past it, and `Read` rules do not stop
`Bash(cat ~/.pass/agents.kdbx)`. And none of it constrains a wrapper the agent
writes itself. They raise the cost of the obvious mistake; the database
boundary is what limits the damage.

**Codex CLI** — approval and sandbox policy live in `~/.codex/config.toml`; there
is no per-command allowlist, so the equivalent is to run with approvals on for
commands outside the sandbox and rely on the instruction in `SKILL.md`.

**Cursor, Copilot, Windsurf and other IDE agents** — command allowlists/denylists
sit in the tool's own settings UI. Add `keepassxc-cli` to the denylist and
`kpsec` to the allowlist.

**Any harness** — a filesystem-level backstop that does not depend on the agent
honouring anything: keep the database outside the workspace (`~/.pass`, not the
repo) so a project-scoped agent cannot read the `.kdbx` at all.
