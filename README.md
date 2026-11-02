# haunt-codex

Reports OpenAI Codex CLI sessions to the [haunt](../../haunt) terminal: running / needs you / done, plan progress, subagents, tool calls and approval prompts. It is the Codex twin of haunt's Claude Code hook (`haunt/hooks/scripts/haunt-hook.sh`). It speaks the same v1 event protocol, with `agent: "codex"`, over the same transport.

## Requirements

- Codex CLI with hooks: checked against 0.136.0. Hooks are on by default; `[features] hooks = false` turns them off.
- `bash`, `jq` 1.6 or newer, and `nc` with `-U` (macOS ships one).

## Install

`haunt setup codex` runs `install.sh` for you. You can also run it yourself:

```sh
./install.sh --dry-run           # print the exact config.toml change as a diff; change nothing
./install.sh --apply             # make it; idempotent
./install.sh --remove [--dry-run]  # take out only our block
```

- **Where.** It edits `$CODEX_HOME/config.toml`, which defaults to `~/.codex/config.toml`.
- **What it writes.** It appends the block below between `# >>> haunt-codex >>>` and `# <<< haunt-codex <<<` markers, using this checkout's absolute path. Lines outside the markers are never changed. A stale block, from a moved checkout, is replaced.
- **Backups.** Every write first copies the config to `config.toml.haunt-codex-<time>-<random>`. The new file is written to a temp file and renamed into place, which keeps the config's mode; a new config is created 0600.
- **Round trip.** `--apply` then `--remove` restores the original byte for byte, unless it had no trailing newline.
- **What it refuses**, changing nothing:
  - a symlinked `config.toml`
  - a broken marker pair
  - a repo path that would need shell quoting
  - hooks already defined in a form it can't extend: `hooks = {…}`, `hooks.X = …`, `[hooks.SessionStart]` as a plain table, or `SessionStart = …` under `[hooks]`
- **Your own `[[hooks.<Event>]]` entries** are kept alongside ours.

To do it by hand instead, add this to `~/.codex/config.toml`. If the file already has a `[hooks]` table or a `~/.codex/hooks.json`, merge it in by hand; Codex warns when one layer uses both.

```toml
[[hooks.SessionStart]]
[[hooks.SessionStart.hooks]]
type = "command"
command = "/Users/lukaracki/code/haunt-plugins/haunt-codex/bin/haunt-codex-hook"
timeout = 5

[[hooks.UserPromptSubmit]]
[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = "/Users/lukaracki/code/haunt-plugins/haunt-codex/bin/haunt-codex-hook"
timeout = 5

[[hooks.PreToolUse]]
[[hooks.PreToolUse.hooks]]
type = "command"
command = "/Users/lukaracki/code/haunt-plugins/haunt-codex/bin/haunt-codex-hook"
timeout = 5

[[hooks.PermissionRequest]]
[[hooks.PermissionRequest.hooks]]
type = "command"
command = "/Users/lukaracki/code/haunt-plugins/haunt-codex/bin/haunt-codex-hook"
timeout = 5

[[hooks.PostToolUse]]
[[hooks.PostToolUse.hooks]]
type = "command"
command = "/Users/lukaracki/code/haunt-plugins/haunt-codex/bin/haunt-codex-hook"
timeout = 5

[[hooks.SubagentStart]]
[[hooks.SubagentStart.hooks]]
type = "command"
command = "/Users/lukaracki/code/haunt-plugins/haunt-codex/bin/haunt-codex-hook"
timeout = 5

[[hooks.SubagentStop]]
[[hooks.SubagentStop.hooks]]
type = "command"
command = "/Users/lukaracki/code/haunt-plugins/haunt-codex/bin/haunt-codex-hook"
timeout = 5

[[hooks.Stop]]
[[hooks.Stop.hooks]]
type = "command"
command = "/Users/lukaracki/code/haunt-plugins/haunt-codex/bin/haunt-codex-hook"
timeout = 5
```

Then start `codex` and run `/hooks`. Codex runs user hooks only after you have reviewed and trusted them there. The trust is tied to each hook's hash, so trust them again after you edit the snippet.

The matchers are left out, so every hook matches every tool. The hooks stay synchronous (no `async = true`) because haunt needs them in order: `tool_start` before `permission_seen` before `tool_ran`.

Newer Codex releases document an `Interrupt` event, which 0.136.0 does not have. Once yours has it, add the same block for `Interrupt`. The script maps it to `stop`.

### Without hooks: `notify`

On a Codex with no hooks, the legacy `notify` program still reports turn ends. Put this line at the very top of `config.toml`, before any `[table]`:

```toml
notify = ["/Users/lukaracki/code/haunt-plugins/haunt-codex/bin/haunt-codex-hook", "notify"]
```

That gives only `stop`, once per turn. Use the hooks or `notify`, not both: with both, every turn sends two `stop`s. That is harmless, but it is noise.

## What it sends

The script reads the hook JSON on stdin and dispatches on `hook_event_name`.

| Codex | haunt event(s) | Notes |
|---|---|---|
| `SessionStart` | `session_start` | `model`, `source`, `plugin_version` |
| `UserPromptSubmit` (main thread) | `prompt_submit` | `query` is the prompt. Dropped inside a subagent, because there the prompt is the parent's message to it. |
| `PreToolUse` | `tool_start` | `tool_name`, `tool_use_id`, `tool_input` preview |
| `PreToolUse` `spawn_agent` | + `subagent_spawn` | `agent_type` (default `default`, which matches `SubagentStart`). `description` is the `task_name`, else the first line of `message` (at most 80 characters). |
| `PreToolUse` `request_user_input` | + `question_asked` | The core puts the row into needs you (status only). |
| `PermissionRequest` | `permission_seen` | `tool_name`, `tool_input` (`command` / `file_path`). It has no `tool_use_id`; the core takes it from the matching `tool_start`. |
| `PostToolUse` `update_plan` | `todos_written` | `tool_count` is the number of plan steps; `todos_done` is the number with status `completed` |
| `PostToolUse` `apply_patch` | `file_edited` × each file (at most 20) | |
| `PostToolUse` | `tool_done`, `tool_ran` | `tool_ran` drops `url` |
| `PostToolUse` inside a subagent | + `subagent_tool` | |
| `SubagentStart` / `SubagentStop` | `subagent_start` / `subagent_stop` | `agent_id` is the subagent's thread id |
| `Stop`, `Interrupt` | `stop` | |
| `notify` `agent-turn-complete` | `stop` | `session_id` is `thread-id` |
| `PreCompact`, `PostCompact`, `SessionEnd` | nothing | |

The `tool_input` preview is a subset of `command`, `url` and `file_path`, the same rule as the Claude hook. Codex reports every shell call (`shell`, `exec_command`) as `Bash` with a string `command`. `apply_patch` sends the whole patch as `command`. The script sends every file it touches (`Add`, `Update`, `Delete` and `Move to` targets, each once, in patch order), made absolute against `cwd` and joined by newlines, as `file_path`. The approval preview then reads `apply_patch /w/src/a.rs⏎/w/b.rs`, never a wall of diff, and never one file for a patch that writes several. haunt answers `apply_patch` only in the terminal.

## Transport and security

This is the same as `haunt-hook.sh`, with the helpers copied rather than imported:

- It does nothing unless `HAUNT=1`.
- **Socket first.** If `HAUNT_SOCK` is a socket and `HAUNT_SURFACE_ID` is set, it sends one JSON line per event to `nc -U -w 2`, carrying `surface_id` and `nonce`. If the send fails, or there is no `nc`, the event is dropped. It is never downgraded to OSC.
- **The nonce** comes from `$HAUNT_HOOK_NONCE`. jq reads it through `$ENV`, so it never appears on a command line. If it is unset, `nonce` is omitted.
- **Sanitising.** Every string but those in `tool_input` has C0/C1 controls, DEL and Unicode Cf (bidi overrides, zero-widths, BOM, soft hyphen, tags) removed before it is encoded. `tool_input` goes raw over the socket (JSON escapes keep it on one line; the hook escapes the C1 controls jq leaves raw, since the core drops a line holding a raw control character), so haunt shows a hidden newline or bidi override in the approval preview and answers such a request only in the terminal.
- **Size caps.** Socket lines are at most 60,000 bytes. Bulky fields are cut in a fixed order and marked `truncated: true`. If they are still too big, the line falls back to the id-only envelope. If even that is too big, the event is dropped. OSC bodies are at most 250 bytes.
- **OSC 777 fallback** happens only when there is no socket. It sends the status-only body to `/dev/tty`, with no nonce, cwd, session id, prompt or command. **It never writes to stdout.** Codex adds plain hook stdout to the model's context on `SessionStart`, `UserPromptSubmit` and `SubagentStart`, so the Claude hook's `terminalSequence` trick would leak into the conversation. With no tty, the event is dropped.
- It always exits 0 and prints nothing, so Codex never sees a decision from it.

## Tests

```sh
tests/run.sh       # the hook
tests/install.sh   # install.sh, against a temp HOME
```

These are plain bash plus jq, `nc` and a perl listener on a temp socket. They cover every mapped event, the subagent and `notify` paths, the nonce, HAUNT gating, control and Cf stripping, raw `tool_input` (including patch paths), every patch path, the socket cap and truncation, a dead socket, the OSC body and its 250-byte cap across every event, the three fallback triggers, no `nc`, and an empty stdout on every path.

## Limits

See `CORE-CHANGES.md` for what the core needs before Codex rows look right.

- **Denied or failed calls send nothing.** Codex runs `PostToolUse` only for calls that succeeded, and has no failure hook. After you deny a prompt, the row stays in needs you until the next prompt or `Stop`, the same as a denial typed into Claude Code.
- **A long-running `exec_command`** (one that returns a process id and keeps going) gets no `PostToolUse` until a later poll.
- **Auto-review.** With approvals reviewed automatically, `PermissionRequest` still fires, so the row shows needs you until the call runs.
- **No idle or notification hook**, and no session end on 0.136.0.
- **Subagents** carry no tool count or duration from the parent, so the subrow counts the subagent's own tools.
