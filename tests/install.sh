#!/bin/bash
# Tests for install.sh, always against a temp HOME. Usage: tests/install.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd -P)"
INSTALL="$ROOT/install.sh"
HOOK="$ROOT/bin/haunt-codex-hook"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
t() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi }

REAL="$HOME/.codex/config.toml"
real_sum() { [ -f "$REAL" ] && cksum < "$REAL" || echo none; }
REAL_BEFORE=$(real_sum)

export HOME="$TMP/home"
unset CODEX_HOME
mkdir -p "$HOME"
CFG="$HOME/.codex/config.toml"
inst() { "$INSTALL" "$@" > "$TMP/out" 2> "$TMP/err"; }
sum() { cksum < "$CFG"; }
backups() { find "$HOME/.codex" -name 'config.toml.haunt-codex-*' 2> /dev/null | wc -l | tr -d ' '; }
blocks() { grep -c '^# >>> haunt-codex >>>' "$CFG"; }
# The result must be valid TOML; checked when uv can run Python 3.11+.
toml_ok() {
    command -v uv > /dev/null || return 0
    uv run --no-project --quiet python -I -c 'import sys, tomllib; d = tomllib.load(open(sys.argv[1], "rb")); print(len(d.get("hooks", {}).get("Stop", [])))' "$1"
}

t "bash -n install.sh" 'bash -n "$INSTALL"'
inst; t "no arguments is a usage error" '[ $? -eq 2 ]'
inst --bogus; t "unknown argument is a usage error" '[ $? -eq 2 ]'
inst --apply --remove; t "--apply with --remove is a usage error" '[ $? -eq 2 ]'

# Fresh HOME, no ~/.codex.
inst --dry-run
t "dry-run on a missing config exits 0" '[ $? -eq 0 ]'
t "dry-run creates nothing" '[ ! -e "$HOME/.codex" ]'
t "dry-run prints the 8 hook commands" '[ "$(grep -c "^+command = \"$HOOK\"$" "$TMP/out")" -eq 8 ]' "$(cat "$TMP/out")"
t "dry-run prints only additions" '! grep -q "^-[^-]" "$TMP/out"'
inst --apply
t "apply on a missing config exits 0" '[ $? -eq 0 ]'
t "apply creates config.toml with one block" '[ "$(blocks)" -eq 1 ]'
t "a new config is 0600" '[ "$(stat -f %Lp "$CFG")" = 600 ]'
t "a new ~/.codex is 0700" '[ "$(stat -f %Lp "$HOME/.codex")" = 700 ]'
t "no backup when there was nothing" '[ "$(backups)" -eq 0 ]'
t "apply tells the user to trust the hooks in /hooks" 'grep -q "/hooks" "$TMP/out"'
t "fresh config is valid TOML with one Stop hook" '[ "$(toml_ok "$CFG")" = 1 ] || ! command -v uv > /dev/null'
for e in SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse SubagentStart SubagentStop Stop; do
    grep -qx "\[\[hooks.$e.hooks\]\]" "$CFG" || bad "block has $e"
done
ok "block has all 8 events"
s1=$(sum)
inst --apply
t "second apply is a no-op" '[ "$(sum)" = "$s1" ] && grep -q "already installed" "$TMP/out" && [ "$(backups)" -eq 0 ]'
inst --dry-run
t "dry-run when installed reports no change" 'grep -q "already installed" "$TMP/out"'

# README's snippet is exactly what install.sh writes.
# The README shows a placeholder path, rewritten to this checkout before the diff.
sed -n '/^```toml$/,/^```$/p' "$ROOT/README.md" | sed '1d;$d' | awk 'BEGIN{n=0} /^```/{exit} {print}' \
    | sed "s|/absolute/path/to/haunt-codex|$ROOT|g" > "$TMP/readme"
sed '1d;$d' "$CFG" > "$TMP/block"
t "README snippet matches the installed block" 'diff -q "$TMP/readme" "$TMP/block" > /dev/null' "$(diff "$TMP/readme" "$TMP/block" | head -5)"

inst --remove
t "remove exits 0" '[ $? -eq 0 ]'
t "remove leaves an empty config" '[ ! -s "$CFG" ]'
t "remove backs the old config up" '[ "$(backups)" -eq 1 ]'
inst --remove
t "second remove is a no-op" 'grep -q "not installed" "$TMP/out" && [ "$(backups)" -eq 1 ]'

# An existing config with tables, comments and its own Stop hook.
rm -f "$HOME"/.codex/config.toml.haunt-codex-*
cat > "$CFG" <<'EOF'
model = "gpt-5.5"   # keep this comment
approval_policy = "on-request"

[tui]
notifications = true

[[hooks.Stop]]
[[hooks.Stop.hooks]]
type = "command"
command = "say done"

[mcp_servers.fs]
command = "npx"
EOF
chmod 644 "$CFG"
cp "$CFG" "$TMP/orig"
inst --apply --dry-run
t "dry-run prints a diff and changes nothing" 'cmp -s "$CFG" "$TMP/orig" && grep -q "^+# >>> haunt-codex >>>" "$TMP/out"'
inst --apply
t "apply keeps the user's config verbatim at the top" '[ "$(head -c "$(wc -c < "$TMP/orig")" "$CFG")" = "$(cat "$TMP/orig")" ]'
t "apply backs up the exact original" '[ "$(backups)" -eq 1 ] && cmp -s "$(find "$HOME/.codex" -name "config.toml.haunt-codex-*")" "$TMP/orig"'
t "apply keeps the config mode" '[ "$(stat -f %Lp "$CFG")" = 644 ]'
t "merged config is valid TOML with both Stop hooks" '[ "$(toml_ok "$CFG")" = 2 ] || ! command -v uv > /dev/null' "$(toml_ok "$CFG" 2>&1)"
inst --remove --dry-run
t "remove dry-run prints only deletions and changes nothing" '! grep -q "^+[^+]" "$TMP/out" && grep -q "^-# >>> haunt-codex >>>" "$TMP/out" && [ "$(blocks)" -eq 1 ]'
inst --remove
t "apply then remove restores the original byte for byte" 'cmp -s "$CFG" "$TMP/orig"'

# A block from a moved repo is replaced, not duplicated.
{ cat "$TMP/orig"; printf '\n# >>> haunt-codex >>> (managed by /old/place/install.sh)\n[[hooks.Stop]]\n[[hooks.Stop.hooks]]\ntype = "command"\ncommand = "/old/place/bin/haunt-codex-hook"\n# <<< haunt-codex <<<\n'; } > "$CFG"
inst --apply
t "apply replaces a stale block" '[ "$(blocks)" -eq 1 ] && ! grep -q /old/place "$CFG" && grep -q "command = \"$HOOK\"" "$CFG"'
inst --remove
t "remove after replace restores the original" 'cmp -s "$CFG" "$TMP/orig"'

# No trailing newline.
printf 'model = "o3"' > "$CFG"
inst --apply && inst --remove
t "a config without a trailing newline survives apply and remove" '[ "$(cat "$CFG")" = "model = \"o3\"" ]'

# Configs this script must not touch.
for bad_cfg in 'hooks = { }' $'[hooks.Stop]\nx = 1' 'hooks.Stop = []' $'[hooks]\nPreToolUse = []'; do
    printf '%s\n' "$bad_cfg" > "$CFG"; cp "$CFG" "$TMP/b"
    inst --apply; rc=$?
    t "refuses to extend: $(printf '%s' "$bad_cfg" | tr '\n' ' ')" '[ $rc -ne 0 ] && cmp -s "$CFG" "$TMP/b" && grep -q "by hand" "$TMP/err"'
done
printf 'a = 1\n# >>> haunt-codex >>> (managed)\n[[hooks.Stop]]\n' > "$CFG"; cp "$CFG" "$TMP/b"
inst --apply; r1=$?
inst --remove; r2=$?
t "refuses a block with no end marker" '[ $r1 -ne 0 ] && [ $r2 -ne 0 ] && cmp -s "$CFG" "$TMP/b"'
printf 'a = 1\n' > "$TMP/target"; rm -f "$CFG"; ln -s "$TMP/target" "$CFG"
inst --apply
t "refuses a symlinked config" '[ $? -ne 0 ] && [ -L "$CFG" ] && [ "$(cat "$TMP/target")" = "a = 1" ]'
rm -f "$CFG"

# CODEX_HOME is honoured.
CODEX_HOME="$TMP/ch" inst --apply
t "CODEX_HOME is used instead of ~/.codex" '[ -f "$TMP/ch/config.toml" ] && [ ! -e "$CFG" ]'

# A repo path that would need quoting is refused.
mkdir -p "$TMP/a b"
cp -R "$ROOT/bin" "$ROOT/install.sh" "$TMP/a b/"
"$TMP/a b/install.sh" --apply > /dev/null 2> "$TMP/err"
t "refuses a repo path with a space" '[ $? -ne 0 ] && grep -q quoting "$TMP/err" && [ ! -e "$CFG" ]'

t "the real ~/.codex/config.toml is untouched" '[ "$(real_sum)" = "$REAL_BEFORE" ]'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
