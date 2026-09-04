# Setup notes

## Requirements

The scripts are `bash` (Linux, macOS) and PowerShell (Windows). There is no
language runtime to install.

| Component | Why | Required |
|---|---|---|
| `keepassxc-cli` ≥ 2.7 | reads the database | yes |
| `secret-tool` (libsecret) | master password in the desktop keyring | Linux |
| `security` | same, via the login Keychain | ships with macOS |
| Credential Manager | same, via the native API | ships with Windows |
| `keyctl` (keyutils) | in-memory cache with a TTL (Linux only) | optional |
| `kdialog`, `zenity` or `pinentry` | prompts and one-off displays | optional |

```bash
# Debian/Ubuntu
sudo apt install keepassxc libsecret-tools keyutils

# openSUSE
sudo zypper install keepassxc secret-tool keyutils

# Fedora
sudo dnf install keepassxc libsecret keyutils

# macOS — Keychain and osascript are already there
brew install keepassxc

# Windows — Credential Manager and PowerShell are already there
winget install KeePassXCTeam.KeePassXC
```

macOS uses the login Keychain and Windows the Credential Manager — see
[`platforms.md`](platforms.md), which also covers tiling WMs without a keyring.

## First run

```bash
./install.sh --bin         # install for detected harnesses and put kpsec on PATH
kpsec init                 # creates the database, generates and stores the master key
kpsec status               # should print "unlock: ok"
```

Without `--bin` the commands live at `<skill>/scripts/kpsec`, where `<skill>` is
the install path for your harness (`~/.claude/skills/keepassxc-secrets`,
`~/.codex/skills/keepassxc-secrets`, `<project>/.cursor/skills/keepassxc-secrets`,
…). `./install.sh --list` prints them.

`init` shows the generated master password once — in a GUI dialog, or on the
terminal if there is no dialog — *before* it creates anything, and refuses to
create the database at all if it cannot show it to you. Copy it into your main
password manager: it is your only way back in if the desktop keyring is lost.
To see it again: `kpsec show-master`.

To open the database by hand, point KeePassXC at `~/.pass/agents.kdbx`
and use that master password.

## Which keyring is actually used

The scripts talk to whatever owns `org.freedesktop.secrets`:

- **KDE Plasma 6** — `ksecretd`, exposing the `kdewallet` collection. Note that
  `kwallet-query` will not find these entries: it speaks the older
  `org.kde.kwalletd6` interface and reports "folder does not exist". This is
  expected, not a broken setup.
- **GNOME** — `gnome-keyring-daemon`, the `login` collection.
- **Anything else with libsecret** — works as long as a provider is registered.

Check what is running:

```bash
busctl --user list | grep secrets
secret-tool search --all application kpsec
```

If the collection is locked, the scripts fall back to a GUI password prompt.

## Headless use

Set `KPSEC_NO_GUI=1` so nothing tries to open a dialog. Then give `kpsec` a way
to obtain the master password, in one of two ways:

- a keyring entry written beforehand (`kpsec init` on a session that has one, or
  `secret-tool store` by hand), or
- `KPSEC_MASTER_COMMAND` — a command whose first line of output is the master
  password. It runs through a shell, so anything that prints the password works:

```bash
export KPSEC_NO_GUI=1
export KPSEC_MASTER_COMMAND='op read op://vault/agents-kdbx/password'
kpsec run -e TOKEN=kp://gitlab/api -- ./deploy.sh
```

Without either, the commands exit with code 4 (and `init` and `show-master`
with 6 — they have nowhere to display the password). Do not put the master
password in a command line argument or a committed file.

## Moving the database

Keyring entries are keyed by the database path, so a moved `.kdbx` leaves its
master key pointing at a path that no longer exists. Re-point it after the move:

```bash
mv ~/.pass/agents.kdbx ~/vault/agents.kdbx
KPSEC_DB=~/.pass/agents.kdbx kpsec relocate ~/vault/agents.kdbx
```

`relocate` copies the key to the new path, verifies the database actually opens
with it, and only then removes the old entry — a wrong target leaves everything
untouched. If the new location is not the default, export `KPSEC_DB` or record
it in `~/.config/kpsec/config`, which is a plain `KEY=value` file (not shell:
it is parsed, never sourced, and unknown keys are ignored with a warning):

```
KPSEC_DB=~/vault/agents.kdbx
KPSEC_TTL=900
```

Values already in the environment win over the file, so
`KPSEC_DB=… kpsec ls` still overrides it. Recognised keys are `KPSEC_DB`,
`KPSEC_TTL`, `KPSEC_KEYRING`, `KPSEC_KEEPASSXC_CLI`, `KPSEC_MASTER_COMMAND`,
`KPSEC_NO_GUI` and `KPSEC_PROMPT_TIMEOUT`.

## Multiple databases

```bash
KPSEC_DB=~/work/secrets.kdbx kpsec init
KPSEC_DB=~/work/secrets.kdbx kpsec ls
```

Keyring entries are keyed by database path, so several databases coexist without
stepping on each other.
