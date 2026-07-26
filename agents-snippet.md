Secrets (passwords, tokens, API keys) live in a local KeePassXC database and are
reached only through the `kpsec` CLI. Never print a secret and never call
`keepassxc-cli` directly — its output goes straight into the transcript.

- Reference form: `kp://<group>/<entry>[#<Attribute>]` (default attribute `Password`).
- Use a secret: `kpsec run -e VAR=kp://group/entry -- <command>` — the value is
  placed in the child process environment and redacted from its output.
- Verify a reference without revealing it: `kpsec check kp://group/entry`.
- List what exists: `kpsec ls`. Diagnose access: `kpsec status`.
- Adding a secret is a human action: `kpsec add <group>/<entry> -u <user>` opens a
  GUI dialog, so the value never passes through the command line. Never use
  `kpsec add --stdin` or `kpsec show-master`.

Full documentation: `skills/keepassxc-secrets/SKILL.md` in the agents-keepassxc-skill
installation (see `references/security.md` for the threat model).
