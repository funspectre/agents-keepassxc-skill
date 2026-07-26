---
name: keepassxc-secrets
description: Use when a command needs a password, token or API key that lives in a local KeePassXC database — inject it into a CLI without ever printing the value, or log in to ArgoCD with the admin password from KeePassXC. Covers kp:// secret references, kpsec run/check/add and argologin.
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
argocd login ... --password "$(...)"       # the password is visible in /proc/*/cmdline
export TOKEN=$(...)                        # the value sticks in history and logs
```

Instead:

```bash
kpsec run -e TOKEN=kp://gitlab/api -- some-cli   # secret only in the child's env
kpsec check kp://gitlab/api                      # verify without revealing
argologin production                             # login with no password in argv
```

## Reference format

```
kp://<group>/<entry>[#<Attribute>]
```

The default attribute is `Password`. Public attributes (`UserName`, `Title`,
`URL`, `Notes`) are not redacted in output; everything else is.

## kpsec

```bash
kpsec status                              # database, cache, unlock check
kpsec ls                                  # entries, without values
kpsec check kp://argocd/production        # OK + length and sha256 prefix
kpsec run -e TOKEN=kp://gitlab/api -- glab api /user
kpsec run --env-file=.env.tpl -- docker compose up
kpsec add gitlab/api -u alice             # value typed by a human in a GUI dialog
kpsec add gitlab/api -g -L 32             # generate a random value
kpsec clip kp://argocd/production         # clipboard for 15 seconds
kpsec lock                                # drop the cached master password
```

`.env.tpl` is a plain env file whose values are either literals or `kp://`
references. It is safe to commit — it holds no values:

```
ARGOCD_AUTH_TOKEN=kp://argocd/production
REGISTRY_USER=deployer
REGISTRY_PASSWORD=kp://registry/deployer
```

Commands an agent must **not** run: `kpsec add --stdin` (the value would land in
argv) and `kpsec show-master`. Those are for the human at the keyboard.

## argologin — ArgoCD login

```bash
argologin list                          # aliases and the references behind them
argologin production                    # writes the token into ~/.config/argocd/config
argologin production --no-switch        # do not make it the current context
argologin production --refresh          # ignore the cached token
argologin production --logout           # drop the cached token
```

Afterwards the plain CLI works as usual:

```bash
argocd app list --argocd-context production
```

Stateless mode — nothing is written to the persistent config; the token lives in
a tmpfs file that is deleted when the command exits:

```bash
argologin production -- argocd app list
```

The token comes from `POST /api/v1/session` (password in the body, never in argv)
and is cached in the kernel keyring for 8 hours.

### Protected instances

For aliases marked `protected`, mutating verbs (`sync`, `delete`, `rollback`,
`patch`, `set`, `create`, …) are refused in stateless mode with exit code 3.
A change the user has already approved:

```bash
ARGO_ALLOW_WRITE=1 argologin production -- argocd app sync my-app
```

Going through `argocd` directly after `argologin` bypasses this guard — there the
usual rule applies: no production changes without user confirmation.

## Adding a new target

1. Store the secret: `kpsec add argocd/<alias> -u admin --url https://<host>`
   (the human types the value into the GUI dialog).
2. Add a tab-separated row to `~/.config/kpsec/argocd.tsv`:
   `alias<TAB>server<TAB>grpc_web<TAB>insecure<TAB>protected<TAB>kp://argocd/alias`.
   Behind an nginx ingress `grpc_web` is almost always `true`.
3. Verify: `kpsec check kp://argocd/<alias>` and `argologin <alias>`.

## Troubleshooting

- `kpsec status` shows where the master password comes from and whether the
  database opens.
- `unlock: FAILED` — the key in Secret Service does not match the database.
- `kdialog`/`zenity` need a graphical session. For headless runs set
  `KPSEC_NO_GUI=1`; the scripts then fail with exit code 4 instead of hanging.
- Environment: `KPSEC_DB`, `KPSEC_TTL`, `KPSEC_TARGETS`, `ARGOCD_TOKEN_TTL`.
- See `references/security.md` for the threat model and `references/setup.md`
  for keyring specifics on KDE/GNOME.
