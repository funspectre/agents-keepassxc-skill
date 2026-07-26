#!/usr/bin/env python3
"""kpsec — read secrets from KeePassXC without leaking values into agent context."""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import NoReturn

DEFAULT_DB = Path.home() / ".pass" / "agents.kdbx"
DEFAULT_TTL = 900
CONFIG_PATH = Path(os.environ.get("KPSEC_CONFIG", Path.home() / ".config" / "kpsec" / "config.json"))
REF_RE = re.compile(r"^kp://(?P<path>[^#\s]+)(?:#(?P<attr>[A-Za-z0-9_. -]+))?$")
PUBLIC_ATTRS = {"username", "title", "url", "notes"}


def die(msg, code=1) -> NoReturn:
    print(f"kpsec: {msg}", file=sys.stderr)
    sys.exit(code)


def load_config():
    cfg = {"db": str(DEFAULT_DB), "ttl": DEFAULT_TTL}
    if CONFIG_PATH.exists():
        cfg.update(json.loads(CONFIG_PATH.read_text()))
    if os.environ.get("KPSEC_DB"):
        cfg["db"] = os.environ["KPSEC_DB"]
    if os.environ.get("KPSEC_TTL"):
        cfg["ttl"] = int(os.environ["KPSEC_TTL"])
    cfg["db"] = str(Path(cfg["db"]).expanduser())
    return cfg


def keyring_desc(db):
    return "kpsec:master:" + hashlib.sha256(db.encode()).hexdigest()[:16]


def keyctl_read(desc):
    if not shutil.which("keyctl"):
        return None
    r = subprocess.run(["keyctl", "search", "@u", "user", desc],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None
    p = subprocess.run(["keyctl", "pipe", r.stdout.strip()], capture_output=True)
    return p.stdout.decode() if p.returncode == 0 else None


def keyctl_write(desc, secret, ttl):
    if not shutil.which("keyctl") or ttl <= 0:
        return
    r = subprocess.run(["keyctl", "padd", "user", desc, "@u"],
                       input=secret.encode(), capture_output=True)
    if r.returncode == 0:
        subprocess.run(["keyctl", "timeout", r.stdout.decode().strip(), str(ttl)],
                       capture_output=True)


def keyctl_unlink(desc):
    if not shutil.which("keyctl"):
        return False
    r = subprocess.run(["keyctl", "search", "@u", "user", desc],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return False
    subprocess.run(["keyctl", "unlink", r.stdout.strip(), "@u"], capture_output=True)
    return True


def keyctl_get(db):
    return keyctl_read(keyring_desc(db))


def keyctl_put(db, secret, ttl):
    keyctl_write(keyring_desc(db), secret, ttl)


def keyctl_drop(db):
    return keyctl_unlink(keyring_desc(db))


def keyring_attrs(db):
    return {"application": "kpsec", "db": db}


def secretservice_get(db):
    try:
        import secretstorage
    except ImportError:
        return None
    try:
        bus = secretstorage.dbus_init()
        col = secretstorage.get_default_collection(bus)
        if col.is_locked():
            col.unlock()
        for item in col.search_items(keyring_attrs(db)):
            return item.get_secret().decode()
    except Exception:
        return None
    return None


def secretservice_put(db, secret):
    import secretstorage
    bus = secretstorage.dbus_init()
    col = secretstorage.get_default_collection(bus)
    if col.is_locked():
        col.unlock()
    col.create_item(f"kpsec master key ({Path(db).name})", keyring_attrs(db),
                    secret.encode(), replace=True)


def secretservice_delete(db):
    try:
        import secretstorage
    except ImportError:
        return False
    bus = secretstorage.dbus_init()
    col = secretstorage.get_default_collection(bus)
    if col.is_locked():
        col.unlock()
    deleted = False
    for item in col.search_items(keyring_attrs(db)):
        item.delete()
        deleted = True
    return deleted


def gui_prompt(title, text):
    if os.environ.get("KPSEC_NO_GUI"):
        return None
    for cmd in (["kdialog", "--title", title, "--password", text],
                ["zenity", "--password", "--title", title]):
        if shutil.which(cmd[0]):
            r = subprocess.run(cmd, capture_output=True, text=True)
            if r.returncode == 0 and r.stdout.strip():
                return r.stdout.rstrip("\n")
            return None
    return None


def gui_message(title, text):
    if os.environ.get("KPSEC_NO_GUI"):
        return
    for cmd in (["kdialog", "--title", title, "--msgbox", text],
                ["zenity", "--info", "--title", title, "--text", text]):
        if shutil.which(cmd[0]):
            subprocess.run(cmd, capture_output=True)
            return


def get_master(cfg, allow_prompt=True):
    db = cfg["db"]
    for source in (keyctl_get, secretservice_get):
        pw = source(db)
        if pw:
            if source is secretservice_get:
                keyctl_put(db, pw, cfg["ttl"])
            return pw
    if not allow_prompt:
        return None
    pw = gui_prompt("kpsec", f"Master password for {Path(db).name}")
    if pw:
        keyctl_put(db, pw, cfg["ttl"])
    return pw


def kp_run(cfg, args, extra_stdin="", check=True):
    master = get_master(cfg)
    if master is None:
        die("cannot obtain the database master password", 4)
    payload = master + "\n" + extra_stdin
    r = subprocess.run(["keepassxc-cli"] + args, input=payload.encode(),
                       capture_output=True)
    if check and r.returncode != 0:
        err = r.stderr.decode().strip().splitlines()
        die("keepassxc-cli: " + (err[-1] if err else f"exit {r.returncode}"), 5)
    return r


def parse_ref(ref):
    m = REF_RE.match(ref)
    if not m:
        die(f"malformed reference: {ref} (expected kp://group/entry#Attribute)", 2)
    return m.group("path"), m.group("attr") or "Password"


def resolve(cfg, ref, soft=False):
    path, attr = parse_ref(ref)
    r = kp_run(cfg, ["show", "-q", "-s", "-a", attr, cfg["db"], path], check=not soft)
    if soft and r.returncode != 0:
        return None
    return r.stdout.decode().rstrip("\n")


def ensure_groups(cfg, entry_path):
    parts = entry_path.strip("/").split("/")[:-1]
    for i in range(len(parts)):
        kp_run(cfg, ["mkdir", "-q", cfg["db"], "/".join(parts[: i + 1])], check=False)


def fingerprint(value):
    return f"len={len(value)} sha256:{hashlib.sha256(value.encode()).hexdigest()[:8]}"


def read_env_file(path):
    pairs = []
    for i, line in enumerate(Path(path).read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            die(f"{path}:{i}: expected VAR=value")
        k, v = line.split("=", 1)
        pairs.append((k.strip(), v.strip().strip('"').strip("'")))
    return pairs


def build_env(cfg, pairs):
    env = os.environ.copy()
    secrets = []
    for k, v in pairs:
        if v.startswith("kp://"):
            _, attr = parse_ref(v)
            resolved = resolve(cfg, v)
            if not resolved:
                die(f"{v}: empty value in the database", 4)
            if attr.lower() not in PUBLIC_ATTRS:
                secrets.append(resolved)
            v = resolved
        env[k] = v
    return env, secrets


def stream_redacted(proc, secrets):
    """Replace secret values line by line in the child's output."""
    subs = sorted({s for s in secrets if len(s) >= 4}, key=len, reverse=True)
    for line in iter(proc.stdout.readline, b""):
        text = line.decode(errors="replace")
        for s in subs:
            text = text.replace(s, "«redacted»")
        sys.stdout.write(text)
        sys.stdout.flush()


def cmd_run(cfg, args):
    pairs = []
    if args.env_file:
        pairs += read_env_file(args.env_file)
    for item in args.env:
        if "=" not in item:
            die(f"-e expects VAR=reference, got: {item}")
        k, v = item.split("=", 1)
        pairs.append((k, v))
    if not args.command:
        die("no command given after --")
    env, secrets = build_env(cfg, pairs)
    if args.no_redact:
        os.execvpe(args.command[0], args.command, env)
    proc = subprocess.Popen(args.command, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    stream_redacted(proc, secrets)
    return proc.wait()


def cmd_check(cfg, args):
    rc = 0
    for ref in args.refs:
        value = resolve(cfg, ref, soft=True)
        if not value:
            print(f"FAIL {ref}  (no such entry or attribute)")
            rc = 1
        else:
            print(f"OK   {ref}  {fingerprint(value)}")
    return rc


def cmd_ls(cfg, args):
    r = kp_run(cfg, ["ls", "-q", "-R", "-f", cfg["db"], args.group or "/"])
    sys.stdout.write(r.stdout.decode())
    return 0


def cmd_add(cfg, args):
    ensure_groups(cfg, args.path)
    exists = resolve(cfg, f"kp://{args.path}#Title", soft=True) is not None
    verb = "edit" if exists else "add"
    cmd_args = [verb, "-q"]
    if args.username:
        cmd_args += ["-u", args.username]
    if args.url:
        cmd_args += ["--url", args.url]
    if args.generate:
        cmd_args += ["-g", "-L", str(args.length), "-l", "-U", "-n", "-s"]
        kp_run(cfg, cmd_args + [cfg["db"], args.path])
    else:
        value = sys.stdin.read().rstrip("\n") if args.stdin else \
            gui_prompt("kpsec", f"Value for {args.path}")
        if not value:
            die("no value entered", 3)
        kp_run(cfg, cmd_args + ["-p", cfg["db"], args.path], extra_stdin=value + "\n")
    print(f"{verb}ed {args.path}")
    return 0


def cmd_clip(cfg, args):
    path, attr = parse_ref(args.ref)
    kp_run(cfg, ["clip", "-q", "-a", attr, cfg["db"], path, str(args.timeout)])
    print(f"copied {args.ref} to clipboard for {args.timeout}s")
    return 0


def cmd_init(cfg, _args):
    db = Path(cfg["db"])
    if db.exists():
        die(f"database already exists: {db}", 3)
    db.parent.mkdir(parents=True, exist_ok=True)
    gen = subprocess.run(["keepassxc-cli", "generate", "-L", "40", "-l", "-U", "-n"],
                         capture_output=True, text=True, check=True)
    master = gen.stdout.strip()
    r = subprocess.run(["keepassxc-cli", "db-create", "-q", "-p", str(db)],
                       input=f"{master}\n{master}\n".encode(), capture_output=True)
    if r.returncode != 0:
        die("db-create: " + r.stderr.decode().strip(), 5)
    db.chmod(0o600)
    secretservice_put(str(db), master)
    keyctl_put(str(db), master, cfg["ttl"])
    gui_message("kpsec master password",
                f"Created {db}\n\nMaster password (back it up in your main KeePassXC):\n\n{master}\n\n"
                "It is also stored in the Secret Service keyring, which is where the scripts read it from.")
    print(f"created {db}; master key stored in Secret Service, shown in a GUI dialog")
    return 0


def cmd_relocate(cfg, args):
    """Keyring entries are keyed by database path, so a moved file loses its key."""
    new_db = str(Path(args.new_path).expanduser())
    if not Path(new_db).exists():
        die(f"no database at {new_db}", 3)
    if new_db == cfg["db"]:
        die("source and target paths are the same", 3)
    master = get_master(cfg, allow_prompt=True)
    if not master:
        die(f"no master password known for {cfg['db']}", 4)
    new_cfg = {**cfg, "db": new_db}
    secretservice_put(new_db, master)
    keyctl_put(new_db, master, cfg["ttl"])
    if kp_run(new_cfg, ["db-info", "-q", new_db], check=False).returncode != 0:
        secretservice_delete(new_db)
        keyctl_drop(new_db)
        die(f"{new_db} does not open with that master password — nothing changed", 5)
    secretservice_delete(cfg["db"])
    keyctl_drop(cfg["db"])
    print(f"relocated {cfg['db']} -> {new_db}")
    print("set KPSEC_DB or ~/.config/kpsec/config.json if the new path is not the default")
    return 0


def cmd_show_master(cfg, _args):
    master = get_master(cfg, allow_prompt=False)
    if not master:
        die("master password found neither in the kernel keyring nor in Secret Service", 4)
    gui_message("kpsec master password", f"Database: {cfg['db']}\n\nMaster password:\n\n{master}")
    print("master key shown in a GUI dialog")
    return 0


def cmd_status(cfg, _args):
    db = Path(cfg["db"])
    print(f"db:             {db} ({'present' if db.exists() else 'MISSING'})")
    print(f"cache ttl:      {cfg['ttl']}s")
    print(f"keyctl cache:   {'warm' if keyctl_get(str(db)) else 'empty'}")
    print(f"secret service: {'key present' if secretservice_get(str(db)) else 'no key'}")
    if db.exists():
        ok = kp_run(cfg, ["db-info", "-q", str(db)], check=False).returncode == 0
        print(f"unlock:         {'ok' if ok else 'FAILED'}")
    return 0


def cmd_lock(cfg, _args):
    print("keyctl cache dropped" if keyctl_drop(cfg["db"]) else "keyctl cache was empty")
    return 0


def main():
    p = argparse.ArgumentParser(prog="kpsec", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("run", help="run a command with secrets in its environment")
    sp.add_argument("--env-file", help="env file whose values may be kp:// references")
    sp.add_argument("-e", "--env", action="append", default=[], metavar="VAR=kp://ref")
    sp.add_argument("--no-redact", action="store_true",
                    help="exec the command directly, without filtering its output")
    sp.add_argument("command", nargs=argparse.REMAINDER)
    sp.set_defaults(func=cmd_run)

    sp = sub.add_parser("check", help="verify references resolve, without revealing values")
    sp.add_argument("refs", nargs="+")
    sp.set_defaults(func=cmd_check)

    sp = sub.add_parser("ls", help="list entries")
    sp.add_argument("group", nargs="?")
    sp.set_defaults(func=cmd_ls)

    sp = sub.add_parser("add", help="add or update an entry; value is typed into a GUI dialog")
    sp.add_argument("path")
    sp.add_argument("-u", "--username")
    sp.add_argument("--url")
    sp.add_argument("-g", "--generate", action="store_true")
    sp.add_argument("-L", "--length", type=int, default=32)
    sp.add_argument("--stdin", action="store_true",
                    help="read the value from stdin (for humans, not for agents)")
    sp.set_defaults(func=cmd_add)

    sp = sub.add_parser("clip", help="copy a value to the clipboard")
    sp.add_argument("ref")
    sp.add_argument("-t", "--timeout", type=int, default=15)
    sp.set_defaults(func=cmd_clip)

    sp = sub.add_parser("init", help="create the database and its master key")
    sp.set_defaults(func=cmd_init)

    sp = sub.add_parser("relocate", help="re-point the stored master key at a moved database file")
    sp.add_argument("new_path")
    sp.set_defaults(func=cmd_relocate)

    sp = sub.add_parser("show-master", help="show the master password in a GUI dialog, never on stdout")
    sp.set_defaults(func=cmd_show_master)

    sp = sub.add_parser("status", help="database and cache state")
    sp.set_defaults(func=cmd_status)

    sp = sub.add_parser("lock", help="drop the cached master password")
    sp.set_defaults(func=cmd_lock)

    args = p.parse_args()
    if getattr(args, "command", None) and args.command and args.command[0] == "--":
        args.command = args.command[1:]
    sys.exit(args.func(load_config(), args) or 0)


if __name__ == "__main__":
    main()
