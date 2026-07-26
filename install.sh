#!/usr/bin/env bash
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/skills/keepassxc-secrets"
DEST="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}/keepassxc-secrets"
MODE="link"

[[ "${1:-}" == "--copy" ]] && MODE="copy"

missing=()
for bin in keepassxc-cli python3; do
    command -v "$bin" >/dev/null || missing+=("$bin")
done
python3 -c "import secretstorage" 2>/dev/null || missing+=("python3-secretstorage")
python3 -c "import yaml" 2>/dev/null || missing+=("python3-yaml (needed by argologin)")
if ((${#missing[@]})); then
    printf 'missing dependencies: %s\n' "${missing[*]}" >&2
    printf 'see skills/keepassxc-secrets/references/setup.md\n' >&2
    exit 1
fi

if [[ -e "$DEST" || -L "$DEST" ]]; then
    printf '%s already exists; remove it first\n' "$DEST" >&2
    exit 1
fi

mkdir -p "$(dirname "$DEST")"
if [[ "$MODE" == "link" ]]; then
    ln -s "$SRC" "$DEST"
else
    cp -r "$SRC" "$DEST"
fi
printf 'installed %s -> %s (%s)\n' "$DEST" "$SRC" "$MODE"

mkdir -p "$HOME/.config/kpsec"
if [[ ! -f "$HOME/.config/kpsec/argocd.tsv" ]]; then
    cp "$SRC/targets/argocd.tsv.example" "$HOME/.config/kpsec/argocd.tsv"
    chmod 600 "$HOME/.config/kpsec/argocd.tsv"
    printf 'created ~/.config/kpsec/argocd.tsv from the example — edit it before using argologin\n'
fi

cat <<EOF

Next:
  $DEST/scripts/kpsec init
  $DEST/scripts/kpsec status

Add the scripts directory to PATH to type 'kpsec' and 'argologin' directly:
  export PATH="\$PATH:$DEST/scripts"
EOF
