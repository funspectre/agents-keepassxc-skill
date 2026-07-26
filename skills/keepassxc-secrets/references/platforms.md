# Platforms

Two things are platform-specific: **where the master password is stored** and
**how the user is asked for it** when the store has no key yet. Everything else —
`keepassxc-cli`, reference resolution, environment injection — is the same
everywhere.

| | Master key store | Prompt | In-memory cache |
|---|---|---|---|
| Linux / BSD | Secret Service (`secret-tool`) | kdialog, zenity, pinentry | kernel keyring (`keyctl`) |
| macOS | Keychain (`security`) | osascript dialog | none — Keychain is already fast |
| Windows | Credential Manager (native API) | `Get-Credential` dialog | none |

Linux and macOS run `scripts/kpsec` (bash); Windows runs `scripts/kpsec.ps1`
(PowerShell 5.1+, which ships with the OS). Neither needs a language runtime.

`kpsec status` prints the backend actually in use. `KPSEC_KEYRING` pins one
(`secretservice`, `keychain`, `keyring`, `none`); `none` disables the store
entirely, so every call prompts.

## Linux: desktops with a keyring

KDE (`ksecretd`/KWallet) and GNOME (`gnome-keyring`) provide
`org.freedesktop.secrets` and unlock it from your login password through PAM.
Nothing to configure — `kpsec init` writes the key and it is readable for the
rest of the session.

On KDE note that `kwallet-query` will *not* show these entries: it speaks the
older `org.kde.kwalletd6` interface while the Secret Service side lives in
`ksecretd`. Use `kpsec status`, or Seahorse/KeePassXC's own browser.

## Linux: tiling WMs and minimal sessions (Hyprland, Sway, i3, …)

There is usually no keyring running. Two ways out, in order of preference:

**1. KeePassXC as the Secret Service provider.** On a minimal session the
`org.freedesktop.secrets` name is free — exactly the case where KeePassXC's own
integration works. Enable *Tools → Settings → Secret Service Integration*, expose
one group, and keep KeePassXC running. `kpsec` then reads the master key from
KeePassXC itself.

Do not expose the group that holds `agents.kdbx`'s own master password to that
integration if the same KeePassXC instance also holds it — keep the bootstrap
secret in a different database than the one it unlocks.

**2. gnome-keyring standalone.** Works outside GNOME but needs a running daemon
and, for auto-unlock, PAM:

```bash
# session startup (e.g. Hyprland exec-once)
gnome-keyring-daemon --start --components=secrets

# /etc/pam.d/login (or your greeter's PAM file), for unlock at login
auth     optional  pam_gnome_keyring.so
session  optional  pam_gnome_keyring.so auto_start
```

Without PAM the collection stays locked until something unlocks it, and `kpsec`
falls back to a prompt.

### Prompting without kdialog/zenity

`pinentry` is the fallback and it is usually already installed for GnuPG. It
picks its own frontend — Qt, GTK or curses — so it works on a bare TTY as well as
under Wayland. `kpsec` drives it over the Assuan protocol; no configuration
needed beyond having one of `pinentry`, `pinentry-qt`, `pinentry-gnome3`,
`pinentry-gtk-2`, `pinentry-curses` on PATH.

For a headless or scripted session set `KPSEC_NO_GUI=1` — `kpsec` then fails with
exit code 4 instead of trying to open a dialog.

## macOS

```bash
brew install keepassxc            # or the .dmg from keepassxc.org
```

The CLI is inside the app bundle and not on PATH. `kpsec` looks for it at
`/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli` and
`/opt/homebrew/bin/keepassxc-cli`; `KPSEC_KEEPASSXC_CLI` overrides. A symlink
also works:

```bash
ln -s /Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli /usr/local/bin/keepassxc-cli
```

The master key goes into the login keychain as a generic password with service
`kpsec master key` and account = the database path. `kpsec init` adds it with
`-T /usr/bin/security`, so reads from scripts do not raise a dialog. Inspect it
in Keychain Access, or:

```bash
security find-generic-password -s "kpsec master key" -a ~/.pass/agents.kdbx
```

The login keychain unlocks with your account password at login — the same trade
as PAM on Linux: anything running as you can read the key while the session is
unlocked.

There is no `keyctl` on macOS, so there is no short-lived cache; every call goes
to the Keychain, which is fast enough.

## Windows

```powershell
winget install KeePassXCTeam.KeePassXC
.\install.ps1
```

`keepassxc-cli.exe` is not added to PATH by the installer, so `kpsec` also checks
`%ProgramFiles%\KeePassXC\keepassxc-cli.exe` and the x86 variant.

The master key goes into Windows Credential Manager as a generic credential
(DPAPI-protected, per-user) through the `CredRead`/`CredWrite` API, called
directly from PowerShell — no modules to install. Prompts use `Get-Credential`,
which draws a masked dialog.

Run the commands as `powershell -File <skill>\scripts\kpsec.ps1 <command>`, or
dot-source the script if you want the functions in your session.

`install.ps1` prefers symlinks; creating them requires Developer Mode or an
elevated shell, so it silently falls back to copying. With copies, `git pull` no
longer updates the installed skill — re-run the installer.

WSL is a reasonable alternative: inside it everything behaves like Linux, but
remember the database and keyring then live in the WSL user session, not in
Windows.
