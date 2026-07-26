---
name: keepassxc-secrets
description: Use when a command needs a password, token or API key that lives in a local KeePassXC database — resolve it into the command's environment without ever printing the value. Covers kp:// secret references and kpsec run/check/ls/add.
requires:
  bins: ["keepassxc-cli", "python3"]
---

# keepassxc-secrets — secrets from KeePassXC without leaking them

Agent-facing secrets live in a **separate database**, by default
`~/Documents/.pass/agents.kdbx`. Its master password is stored in the desktop
Secret Service keyring (unlocked at login) and cached in the kernel keyring, so
the scripts run without prompting. The user's main database stays out of reach —
that is what bounds the blast radius.

## The one rule

**A secret value must never reach the command output.** It is resolved inside a
child process, and if that process prints it, it is replaced with `«redacted»`.

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

## Reference format

```
kp://<group>/<entry>[#<Attribute>]
```

The default attribute is `Password`. Public attributes (`UserName`, `Title`,
`URL`, `Notes`) are not redacted in output; everything else is.

## Commands

```bash
kpsec status                              # database, cache, unlock check
kpsec ls                                  # entries, without values
kpsec check kp://gitlab/api               # OK + length and sha256 prefix
kpsec run -e TOKEN=kp://gitlab/api -- glab api /user
kpsec run --env-file=.env.tpl -- docker compose up
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

Commands an agent must **not** run: `kpsec add --stdin` (the value would land in
argv) and `kpsec show-master`. Those are for the human at the keyboard.

## Adding a secret

```bash
kpsec add <group>/<entry> -u <username> --url <url>
```

The value is typed into a GUI dialog, so it never passes through the agent's
command line. Verify with `kpsec check kp://<group>/<entry>`.

`keepassxc-cli` cannot set or filter by tags, so entries are organised by group
(`argocd/…`, `gitlab/…`, `registry/…`) and the reference mirrors that path.

## Building tools on top

Wrappers that need a secret should import the core rather than shell out to
`kpsec` — that keeps values out of any intermediate stdout:

```python
import sys
sys.path.insert(0, "/path/to/keepassxc-secrets/scripts")
import kpsec_core as kpsec

cfg = kpsec.load_config()
token = kpsec.resolve(cfg, "kp://gitlab/api")   # stays in memory
proc = subprocess.Popen(cmd, env={**os.environ, "TOKEN": token},
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
kpsec.stream_redacted(proc, [token])            # filter the child's output
```

## Troubleshooting

- `kpsec status` shows where the master password comes from and whether the
  database opens.
- `unlock: FAILED` — the key in Secret Service does not match the database.
- `kdialog`/`zenity` need a graphical session. For headless runs set
  `KPSEC_NO_GUI=1`; the scripts then fail with exit code 4 instead of hanging.
- Environment: `KPSEC_DB`, `KPSEC_TTL`, `KPSEC_CONFIG`.
- See `references/security.md` for the threat model and `references/setup.md`
  for keyring specifics on KDE/GNOME.
