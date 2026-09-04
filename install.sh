#!/usr/bin/env bash
set -euo pipefail

SKILL="keepassxc-secrets"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/skills/$SKILL"
SNIPPET="$ROOT/agents-snippet.md"
BEGIN="<!-- ${SKILL}:begin -->"
END="<!-- ${SKILL}:end -->"
HARNESSES=(claude codex gemini)

MODE="link"
BIN_DIR=""
PROJECT=""
EXTRA_DIRS=()
WANTED=()
ALL_USER=0

user_dir() {
    case "$1" in
        claude) printf '%s\n' "$HOME/.claude/skills" ;;
        codex)  printf '%s\n' "$HOME/.codex/skills" ;;
        gemini) printf '%s\n' "$HOME/.gemini/skills" ;;
        *)      return 1 ;;
    esac
}

detected() {
    case "$1" in
        claude) [[ -d "$HOME/.claude" ]] || command -v claude >/dev/null ;;
        codex)  [[ -d "$HOME/.codex" ]] || command -v codex >/dev/null ;;
        gemini) [[ -d "$HOME/.gemini" ]] || command -v gemini >/dev/null ;;
        *)      return 1 ;;
    esac
}

usage() {
    cat <<EOF
Install the $SKILL skill for coding agents.

  ./install.sh                    install for every detected harness (user scope)
  ./install.sh --user a,b         install for the named harnesses: ${HARNESSES[*]}
  ./install.sh --all-user         install for all known harnesses, detected or not
  ./install.sh --skills-dir DIR   install into an arbitrary skills directory
  ./install.sh --project [DIR]    project scope: .cursor/skills, .agents/skills and
                                  an AGENTS.md pointer block (defaults to \$PWD)
  ./install.sh --bin [DIR]        put kpsec on PATH (defaults to ~/.local/bin)
  ./install.sh --copy             copy instead of symlinking
  ./install.sh --list             show harnesses, target paths and what is detected

Cursor has no personal skills directory, so it needs --project. Harnesses that
read AGENTS.md (Copilot, Windsurf, Aider, Zed, …) are covered by the pointer
block --project writes.
EOF
}

check_deps() {
    local missing=() cli_found=0
    for cli in keepassxc-cli \
               /Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli \
               /opt/homebrew/bin/keepassxc-cli; do
        if command -v "$cli" >/dev/null || [[ -x "$cli" ]]; then cli_found=1; break; fi
    done
    ((cli_found)) || missing+=("keepassxc-cli")
    # keyring: Keychain ships with macOS, Linux needs secret-tool (libsecret)
    if [[ "$(uname -s)" != "Darwin" ]] && ! command -v secret-tool >/dev/null; then
        missing+=("secret-tool (libsecret-tools)")
    fi
    if ((${#missing[@]})); then
        printf 'missing dependencies: %s\n' "${missing[*]}" >&2
        printf 'see skills/%s/references/setup.md\n' "$SKILL" >&2
        exit 1
    fi
}

install_into() {
    local dir="$1" dest="$1/$SKILL"
    if [[ -L "$dest" && "$(readlink -f "$dest")" == "$(readlink -f "$SRC")" ]]; then
        printf '  = %s (already installed)\n' "$dest"
        return
    fi
    if [[ -e "$dest" || -L "$dest" ]]; then
        printf '  ! %s exists and is not our symlink — skipped\n' "$dest" >&2
        return
    fi
    mkdir -p "$dir"
    if [[ "$MODE" == "link" ]]; then
        ln -s "$SRC" "$dest"
    else
        cp -r "$SRC" "$dest"
    fi
    printf '  + %s (%s)\n' "$dest" "$MODE"
}

write_agents_block() {
    local file="$1" tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/keepassxc-secrets.XXXXXX")" ||
        { printf '  ! cannot create a temporary file — %s not written\n' "$file" >&2; return 1; }
    if [[ -f "$file" ]]; then
        awk -v b="$BEGIN" -v e="$END" '
            $0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }
        ' "$file" > "$tmp"
        while [[ -s "$tmp" && -z "$(tail -n 1 "$tmp")" ]]; do
            truncate -s -1 "$tmp"
        done
        [[ -s "$tmp" ]] && printf '\n' >> "$tmp"
    fi
    {
        printf '%s\n## Secrets\n\n' "$BEGIN"
        cat "$SNIPPET"
        printf '%s\n' "$END"
    } >> "$tmp"
    mkdir -p "$(dirname "$file")"
    # Copy into place rather than mv: AGENTS.md keeps its own mode instead of
    # inheriting mktemp's 0600.
    if ! cat "$tmp" > "$file"; then
        rm -f "$tmp"
        printf '  ! cannot write %s\n' "$file" >&2
        return 1
    fi
    rm -f "$tmp"
    printf '  + %s (pointer block)\n' "$file"
}

install_bin() {
    local dir="$1"
    mkdir -p "$dir"
    ln -sfn "$SRC/scripts/kpsec" "$dir/kpsec"
    printf '  + %s/kpsec\n' "$dir"
    case ":$PATH:" in
        *":$dir:"*) ;;
        *) printf '  ! %s is not on PATH — add it to your shell profile\n' "$dir" >&2 ;;
    esac
}

cmd_list() {
    local state
    printf 'skill source: %s\n\nuser scope:\n' "$SRC"
    for h in "${HARNESSES[@]}"; do
        state="not detected"
        detected "$h" && state="detected"
        printf '  %-8s %-28s %s\n' "$h" "$(user_dir "$h")" "$state"
    done
    cat <<EOF

project scope (--project DIR):
  cursor   DIR/.cursor/skills          Cursor has no personal skills directory
  shared   DIR/.agents/skills          Cline, Amp, opencode, Antigravity, …
  pointer  DIR/AGENTS.md               Copilot, Windsurf, Aider, Zed, …
EOF
}

while (($#)); do
    case "$1" in
        --copy) MODE="copy" ;;
        --list) cmd_list; exit 0 ;;
        --all-user) ALL_USER=1 ;;
        --user)
            IFS=, read -ra WANTED <<< "${2:?--user needs a comma-separated list}"
            shift ;;
        --skills-dir)
            EXTRA_DIRS+=("${2:?--skills-dir needs a path}")
            shift ;;
        --project)
            if [[ -n "${2:-}" && "${2:-}" != --* ]]; then PROJECT="$2"; shift; else PROJECT="$PWD"; fi ;;
        --bin)
            if [[ -n "${2:-}" && "${2:-}" != --* ]]; then BIN_DIR="$2"; shift; else BIN_DIR="$HOME/.local/bin"; fi ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

check_deps

if ((${#WANTED[@]} == 0)) && ((ALL_USER == 0)) &&
   [[ -z "$PROJECT" && -z "$BIN_DIR" && ${#EXTRA_DIRS[@]} -eq 0 ]]; then
    for h in "${HARNESSES[@]}"; do
        detected "$h" && WANTED+=("$h")
    done
    if ((${#WANTED[@]} == 0)); then
        printf 'no harness detected; use --all-user, --project or --skills-dir\n' >&2
        exit 1
    fi
fi
((ALL_USER)) && WANTED=("${HARNESSES[@]}")

if ((${#WANTED[@]})); then
    printf 'user scope:\n'
    for h in "${WANTED[@]}"; do
        if dir="$(user_dir "$h")"; then
            install_into "$dir"
        else
            printf '  ! unknown harness: %s\n' "$h" >&2
        fi
    done
fi

if ((${#EXTRA_DIRS[@]})); then
    printf 'custom:\n'
    for dir in "${EXTRA_DIRS[@]}"; do
        install_into "$dir"
    done
fi

if [[ -n "$PROJECT" ]]; then
    printf 'project scope (%s):\n' "$PROJECT"
    install_into "$PROJECT/.cursor/skills"
    install_into "$PROJECT/.agents/skills"
    write_agents_block "$PROJECT/AGENTS.md" || AGENTS_FAILED=1
fi

if [[ -n "$BIN_DIR" ]]; then
    printf 'PATH:\n'
    install_bin "$BIN_DIR"
fi

cat <<EOF

Next:
  $SRC/scripts/kpsec init
  $SRC/scripts/kpsec status
EOF

exit "${AGENTS_FAILED:-0}"
