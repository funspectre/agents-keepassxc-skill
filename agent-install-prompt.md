# Install prompt

Paste the block below into your coding agent (Claude Code, Codex, Cursor, …).
It tells the agent how to install this skill and verify it, and it stops the
agent from doing the one thing it must not do: read a secret into its own
context.

---

Install the KeePassXC secrets skill from https://github.com/jidckii/agents-keepassxc-skill
and set it up for me.

Steps:

1. Check the dependencies for my platform and tell me what to install if something
   is missing. Linux: `keepassxc-cli` and `secret-tool` (package `libsecret-tools`
   on Debian/Ubuntu, `secret-tool` on openSUSE, `libsecret` on Fedora); optionally
   `keyutils`. macOS: `keepassxc-cli` (inside the KeePassXC app bundle) — Keychain
   is already there. Windows: `keepassxc-cli.exe` — Credential Manager and
   PowerShell are already there. Do not install system packages yourself: print
   the command and let me run it.

2. Clone the repository to a directory I will keep (ask me where; a reasonable
   default is `~/repo/agents-keepassxc-skill`) and run `./install.sh --bin`
   (`.\install.ps1` on Windows). It installs into every agent harness it detects
   and puts `kpsec` on PATH. Report which harnesses it found.

3. Run `kpsec init`. It creates `~/.pass/agents.kdbx`, stores the master key in
   the system keyring and shows the master password **once**, in a GUI dialog.
   Tell me to copy that password into my main password manager — if the keyring
   is lost, it is the only way back into the database. Do not try to read or
   print that password yourself.

4. Verify with `kpsec status`. It must print `unlock: ok` and a keyring backend
   other than `none`. If it does not, diagnose from that output.

5. Add my first secret by running `kpsec add <group>/<entry> -u <username>`,
   which opens a GUI dialog for me to type the value into. Ask me for the group,
   entry name and username; never ask me to paste the secret into the chat.
   Then confirm with `kpsec check kp://<group>/<entry>` — it prints the length
   and a machine-local fingerprint, not the value.

6. If this project should use it, run `./install.sh --project .` in the project
   directory: it adds the skill to `.cursor/skills` and `.agents/skills` and
   writes a pointer block into `AGENTS.md`.

Rules while doing this and afterwards:

- Never run `keepassxc-cli` directly, never run `kpsec show-master`, never run
  `kpsec clip`, never run `kpsec add --stdin`. Those either print a secret,
  leave one on the clipboard, or require you to be holding the plaintext.
- To use a secret in a command, always go through
  `kpsec run -e VAR=kp://group/entry -- <command>`. Never `VAR=$(...)`, never
  `--password <value>`.
- `kpsec run` does not filter the command's output. If a tool prints its own
  credentials in verbose or debug mode, say so instead of running it.
