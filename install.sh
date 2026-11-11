#!/bin/bash
# Adds or removes haunt-codex's hook block in Codex's config.toml. Used by `haunt setup codex`.
# Usage: install.sh --dry-run | --apply | --remove [--dry-run]
set -euo pipefail

die() { printf 'haunt-codex: %s\n' "$1" >&2; exit 1; }
usage() { printf 'usage: install.sh --dry-run | --apply | --remove [--dry-run]\n' >&2; exit 2; }

MODE=""
DRY=0
for arg in "$@"; do
    case "$arg" in
        --apply) [ -z "$MODE" ] || usage; MODE=apply ;;
        --remove) [ -z "$MODE" ] || usage; MODE=remove ;;
        --dry-run) DRY=1 ;;
        *) usage ;;
    esac
done
[ -n "$MODE" ] || { [ "$DRY" = 1 ] && MODE=apply; } || usage

ROOT="$(cd "$(dirname "$0")" && pwd -P)"
HOOK="$ROOT/bin/haunt-codex-hook"
DIR="${CODEX_HOME:-$HOME/.codex}"
CONFIG="$DIR/config.toml"
BEGIN='# >>> haunt-codex >>>'
END='# <<< haunt-codex <<<'
EVENTS="SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse SubagentStart SubagentStop Stop"

# Codex runs the command through `$SHELL -lc`, so the path must need no quoting in TOML or in sh.
case "$HOOK" in
    *[!A-Za-z0-9_./-]*) die "the repo path $ROOT needs quoting; move it somewhere without spaces or special characters" ;;
esac
[ -L "$CONFIG" ] && die "$CONFIG is a symlink; refusing to replace it. Add the block from README.md by hand."

block() {
    printf '%s (managed by %s/install.sh; --remove deletes this block)\n' "$BEGIN" "$ROOT"
    local first=1 e
    for e in $EVENTS; do
        [ "$first" = 1 ] || printf '\n'
        first=0
        printf '[[hooks.%s]]\n[[hooks.%s.hooks]]\ntype = "command"\ncommand = "%s"\ntimeout = 5\n' "$e" "$e" "$HOOK"
    done
    printf '%s\n' "$END"
}

CURRENT=""
[ -f "$CONFIG" ] && CURRENT=$(cat "$CONFIG"; printf x) && CURRENT="${CURRENT%x}"

begins=$(printf '%s' "$CURRENT" | grep -c "^$BEGIN" || true)
ends=$(printf '%s' "$CURRENT" | grep -cx "$END" || true)
if [ "$begins" != "$ends" ] || [ "$begins" -gt 1 ]; then
    die "$CONFIG has a broken haunt-codex block ($begins start, $ends end markers); fix it by hand"
fi

# The config without our block, and without the one blank line we put before it.
strip() {
    printf '%s' "$CURRENT" | awk -v b="$BEGIN" -v e="$END" '
        index($0, b) == 1 { held = 0; skip = 1; next }
        skip { if ($0 == e) skip = 0; next }
        $0 == "" { if (held) print ""; held = 1; next }
        { if (held) print ""; held = 0; print }
        END { if (held) print "" }'
}
REST=$(strip; printf x)
REST="${REST%x}"

if [ "$MODE" = apply ]; then
    # A hooks table defined any other way cannot take our [[hooks.<Event>]] entries.
    events_re=$(printf '%s' "$EVENTS" | tr ' ' '|')
    if printf '%s' "$REST" | grep -Eq "^[[:space:]]*hooks[[:space:]]*=|^[[:space:]]*hooks\.[A-Za-z]+[[:space:]]*=|^[[:space:]]*\[hooks\.($events_re)\][[:space:]]*(#.*)?$|^[[:space:]]*($events_re)[[:space:]]*="; then
        die "$CONFIG already defines hooks in a form this script can't extend; merge README.md's snippet by hand"
    fi
    NEW="$REST"
    [ -n "$NEW" ] && NEW+=$'\n'
    NEW+=$(block)$'\n'
else
    NEW="$REST"
fi

if [ "$NEW" = "$CURRENT" ]; then
    if [ "$MODE" = apply ]; then echo "haunt-codex: already installed in $CONFIG"; else echo "haunt-codex: not installed in $CONFIG"; fi
    exit 0
fi

if [ "$DRY" = 1 ]; then
    diff -u --label "$CONFIG" --label "$CONFIG" <(printf '%s' "$CURRENT") <(printf '%s' "$NEW") || true
    exit 0
fi

[ -d "$DIR" ] || mkdir -m 700 -p "$DIR"
TMP=$(mktemp "$DIR/.config.toml.haunt-codex.XXXXXX")
trap 'rm -f "$TMP"' EXIT
if [ -f "$CONFIG" ]; then
    # Unique even within one second, so a quick apply-then-remove never overwrites the first backup.
    BACKUP=$(mktemp "$CONFIG.haunt-codex-$(date +%Y%m%d-%H%M%S)-XXXXXX")
    cp -p "$CONFIG" "$BACKUP"
    # Copying over the temp file first keeps the config's mode.
    cp -p "$CONFIG" "$TMP"
fi
printf '%s' "$NEW" > "$TMP"
mv -f "$TMP" "$CONFIG"
trap - EXIT

[ -n "${BACKUP:-}" ] && echo "haunt-codex: backup at $BACKUP"
if [ "$MODE" = apply ]; then
    echo "haunt-codex: installed in $CONFIG. Start codex and run /hooks to trust the hooks."
    [ -f "$DIR/hooks.json" ] && echo "haunt-codex: note: $DIR/hooks.json also exists; Codex warns when one layer uses both."
    grep -q "^[[:space:]]*notify[[:space:]]*=.*haunt-codex-hook" "$CONFIG" && echo "haunt-codex: note: notify also calls haunt-codex-hook, so each turn sends two stops."
    command -v jq > /dev/null || echo "haunt-codex: note: jq is not on PATH; the hook needs it."
else
    echo "haunt-codex: removed from $CONFIG"
fi
exit 0
