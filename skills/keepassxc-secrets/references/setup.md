# Setup notes

## Requirements

| Component | Why | Required |
|---|---|---|
| `keepassxc-cli` ≥ 2.7 | reads the database | yes |
| `python3` | the scripts | yes |
| `python3-secretstorage` | stores the master password in the desktop keyring | yes |
| `keyctl` (keyutils) | in-memory cache with a TTL | optional |
| `kdialog` or `zenity` | prompts and one-off displays | optional |

```bash
# Debian/Ubuntu
sudo apt install keepassxc python3-secretstorage keyutils

# openSUSE
sudo zypper install keepassxc python3-SecretStorage keyutils

# Fedora
sudo dnf install keepassxc python3-secretstorage keyutils
```

## First run

```bash
kpsec init                 # creates the database, generates and stores the master key
kpsec status               # should print "unlock: ok"
```

`init` shows the generated master password once, in a GUI dialog. Copy it into
your main password manager — it is your only way back into the database if the
desktop keyring is lost. To see it again: `kpsec show-master`.

To open the database by hand, point KeePassXC at `~/Documents/.pass/agents.kdbx`
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
python3 -c "import secretstorage; b=secretstorage.dbus_init(); \
  c=secretstorage.get_default_collection(b); print(c.get_label(), c.is_locked())"
```

If the collection is locked, the scripts fall back to a GUI password prompt.

## Headless use

Set `KPSEC_NO_GUI=1`. Without a keyring entry the scripts then exit with code 4
rather than trying to open a dialog. Provide the master password through the
Secret Service beforehand, or point `KPSEC_DB` at a database you unlock another
way.

## Multiple databases

```bash
KPSEC_DB=~/work/secrets.kdbx kpsec init
KPSEC_DB=~/work/secrets.kdbx kpsec ls
```

Keyring entries are keyed by database path, so several databases coexist without
stepping on each other.
