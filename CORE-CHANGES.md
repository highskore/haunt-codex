# Proposed haunt core changes for Codex rows

These are proposals only; none of them is applied. File and line references are to haunt `master` at `2c026a1` plus the uncommitted work in progress. The adapter already works against today's core for status, progress, subagents and verified requests. Without change 3, though, answering a Codex prompt from haunt is wrong. Section 6 is the agent-neutral event spec that haunt-claude and haunt-codex both follow.

## 1. Keep the agent per session (`agent` field)

`AgentEvent.agent` is already parsed (`core/src/event.rs` `parse_value`, defaults to `"claude"`). Nothing stores it yet.

- `core/src/session.rs`: add `pub agent: Agent` to `Session`, an enum with `Claude` and `Codex` (unknown names map to `Claude`). Set it in `Session::apply`, from **verified** events only, so a forged OSC body can't relabel a row or change its answer bytes.
- `core/src/event.rs`: optionally parse `agent` into that enum, so callers don't compare strings.
- Test: `session.rs` applies a verified `{"agent":"codex","event":"session_start"}`, then checks `s.agent == Agent::Codex`. A second, unverified `{"agent":"claude",…}` leaves it as `Codex`.

## 2. `RowKind::Codex` and its icon

- `core/src/layout.rs` `row()`: `kind: match session.agent { Agent::Codex => RowKind::Codex, _ => RowKind::Claude }`. Add `Codex` to `enum RowKind`.
- `docs/core-api.md`: `enum RowKind { Shell, Claude, Codex }`.
- Swift (`macos/Sources/CoreAPI.swift` `RowKind`, `SidebarView.swift` `drawIcon`, `Draw.swift`, `Tokens.swift`): add `case .codex` with a `Draw.codexMark`, a monochrome glyph at `Tok.Size.claudeIcon` (rename it `agentIcon`). Keep it black and white, like the mockups. A plain hexagon or `>_` mark avoids using OpenAI's logo.
- Test: in `layout.rs`, a session fed codex events gives `RowKind::Codex`. The existing `RowKind::Claude` tests stay green.

## 3. Answer bytes per agent (needed for Allow/Deny)

`core/src/model.rs` `answer_permission` / `answer_by` returns `1` for allow and ESC for deny, both written for Claude Code. In the Codex approval overlay (`codex-rs/tui/src/bottom_pane/approval_overlay.rs`, `keymap.rs` defaults at rust-v0.136.0), the default keys are:

- `y`: proceed
- `a`: allow for the session
- `p`: allow the prefix
- `d`: deny and continue
- `Esc` / `n`: decline and tell Codex

A digit does nothing there. Enter takes whichever row is highlighted.

- Change: pick the bytes from the session's agent. For Codex, allow is `y` and deny is `\x1b`. ESC is Codex's list cancel, so it declines the call and returns to the prompt, the same as Claude.
- Test: in `model.rs`, a verified codex `permission_seen` gives `answer_permission(.., true) == Some(b"y")` and `(.., false) == Some(b"\x1b")`. The Claude tests are unchanged.

## 4. Allowlist suggestions are Claude-only

`core/src/allowlist.rs` writes `Bash(<cmd>)` into `<project>/.claude/settings.local.json`. That file means nothing to Codex, whose rules live in `~/.codex/rules` / execpolicy.

- Change: add the agent to `Decision` (`core/src/decisions.rs`; serde default `claude` keeps old log lines valid). In `model.rs` `suggestions()`, count only Claude decisions.
- Test: 3 verified `AnsweredInTerminal` approvals of the same codex `Bash` command give no `allow_suggestions()`.

## 5. Events

No new event is required. The adapter maps everything onto the existing vocabulary.

- `question_asked`, from `request_user_input`, is already handled through `EventKind::Unknown` in `session.rs`. Making it a first-class `EventKind::QuestionAsked` is optional cleanup.
- Codex has no failure hook, no idle notification, and no session end on 0.136.0. A denied call therefore leaves the row in needs you until the next prompt or `stop`, as with Claude. Nothing to add.
- Optional: `hooks/README.md` and `docs/core-api.md` say the `agent` envelope field is "always `claude`". Change that to "`claude` or `codex`".

## 6. Agent event spec v1

This is the contract every adapter (haunt-claude, haunt-codex, and any later one) emits and the core parses. It describes what the core does today (`core/src/event.rs`, `session.rs`, `intake.rs`, `docs/core-api.md`). Where it differs from today, it says so under "Generalise". MUST and SHOULD carry their RFC 2119 meaning.

### Agent identifier

`agent` is a lowercase ASCII id for the coding agent: `claude` (Claude Code) or `codex` (Codex CLI). A new agent takes a new id here. Adapters MUST send it on every event. The core keeps it per session from verified events only (change 1). It picks the row kind, the answer bytes and allowlist eligibility (changes 2 to 4). A missing `agent` means `claude`, but only for compatibility with pre-spec hooks.

### Envelope

Each event is one compact JSON object. Null or absent fields are omitted. The core ignores unknown fields.

| field | type | required | meaning |
|---|---|---|---|
| `v` | int | yes | `1`. The core rejects any other value. |
| `agent` | string | yes | as above |
| `event` | string | yes | an event name below |
| `surface_id` | string | socket only | `$HAUNT_SURFACE_ID`. Lines for an unknown surface are dropped. |
| `nonce` | string | socket only | `$HAUNT_HOOK_NONCE`, omitted when unset |
| `session_id` | string | no | the agent's session or thread id |
| `cwd` | string | no | the agent's working directory. Verified absolute paths become the row's cwd. |
| `agent_id` | string | no | set when a subagent produced the event. On `subagent_result`, the finished subagent. |
| `agent_type` | string | no | the subagent's type or role |
| `permission_mode` | string | no | the agent's own value, passed through (`default`, `plan`, `acceptEdits`, …) |
| `truncated` | bool | no | `true` if any string was cut |

Shared payload fields:

- `tool_name` (string): the agent's own tool name. Shell commands MUST be named `Bash`, because the core previews and allowlists only `Bash`. Both agents already do this.
- `tool_use_id` (string): the agent's call id.
- `tool_input` (object): only `command`, `url` and `file_path`, each a string. An adapter MUST NOT send other inputs (edit bodies, patches, prompts to subagents). For a file-editing tool, `file_path` is the absolute path of the first file it touches.

### Events

An adapter sends the events its agent can observe and leaves the others out. Within one hook, events MUST come in the order listed per hook in the adapter README. The core needs `tool_start` before `permission_seen` before `tool_ran`.

| event | fields | core effect |
|---|---|---|
| `session_start` | `model`, `source`, `plugin_version` (the adapter's version) | makes the surface an agent row |
| `prompt_submit` | `query` | new turn: running, the prompt shown, progress reset. Main thread only. |
| `tool_start` | `tool_name`, `tool_use_id`, `tool_input` | running. Verified ones are kept to supply `tool_use_id` to a later `permission_seen`. |
| `permission_seen` | `tool_name`, `tool_input` (no `url`), `tool_use_id` if known | needs you. Verified and untruncated with a `command`/`file_path`: an answerable request. |
| `tool_ran` | `tool_name`, `tool_use_id`, `tool_input` (no `url`) | resolves a matching request (answered in the terminal) |
| `tool_done` / `tool_failed` | `tool_name`, `tool_use_id`, `tool_input` | same as `tool_ran`, and history |
| `notification` | `notification_type`, `message` | `permission_prompt` gives needs you without a request |
| `question_asked` | none | needs you, status only (today it goes through `Unknown`) |
| `question_answered` | `summary` | none yet |
| `task_created` | `task_id` (string), `task_subject` | progress |
| `task_updated` | `task_id`, `task_status` (`pending`/`in_progress`/`completed`/`deleted`) | progress |
| `todos_written` | `tool_count` (items), `todos_done` | progress when there are no tasks |
| `plan_exit` | `summary` | none yet |
| `file_edited` | `tool_name`, `tool_input.file_path` | none yet |
| `subagent_spawn` | `agent_type`, `description` | queues a label for the next `subagent_start` of that type |
| `subagent_start` / `subagent_stop` | `agent_id`, `agent_type` | subrow on / off |
| `subagent_tool` | `agent_id`, `tool_name` | subrow tool count |
| `subagent_result` | `agent_id`, `agent_type`, `description`, `tool_count`, `duration_ms` | final subrow counts |
| `stop` | none | done |
| `stop_failure` | none | failed (today it goes through `Unknown`) |

The core passes unknown events through as `EventKind::Unknown` and ignores them. A new event is a spec addition, not a version bump. A change in what an existing field means is a bump to `v: 2`.

### Transport

1. **Gate.** An adapter MUST do nothing unless `HAUNT=1`.
2. **Socket.** If `HAUNT_SOCK` is a Unix socket and `HAUNT_SURFACE_ID` is set, the adapter sends one line per event, newline-terminated. A line is at most 60,000 bytes; the core reads lines of at most 64 KB. A failed send MUST be dropped, never downgraded to OSC.
3. **Nonce.** It is copied from the environment and never passed on a command line or written anywhere else. The core counts an event as verified only when it came over the socket with a matching nonce (constant-time compare). Only verified events may create a request, move the row's cwd, enter the decision log or count towards an allowlist suggestion.
4. **OSC 777 fallback.** This is used only when there is no socket: `ESC ] 777 ; notify ; haunt://cli-agent ; <body> BEL`. The body has at most 250 bytes and only `v, agent, event, agent_id, agent_type, task_id, task_status, task_subject, description, tool_name, tool_count, todos_done, notification_type`. It never carries the nonce, cwd, session id, prompt, command or message. The core treats it as status only. The sequence goes wherever the agent lets it reach the terminal: `/dev/tty`, or Claude Code's `terminalSequence`. An adapter MUST NOT print it to stdout where the agent feeds stdout to the model (Codex).
5. **Sanitising.** Before encoding, an adapter removes C0, DEL, C1 and Unicode Cf from every string. The core strips them again after decoding, and rejects a raw control character in an OSC body.
6. **Truncation.** Cut, in order: `tool_input.command`, `url`, `file_path`, `summary`, `query`, `message`, `description`, `task_subject`, `cwd`. Each cut ends with `…` and sets `truncated: true`. If the line still doesn't fit, send only `{v, agent, event, surface_id, session_id, agent_id, tool_use_id, task_id, tool_name, nonce, truncated}`. If that doesn't fit either, drop the event. A truncated event never matches a request.
7. **Exit.** Exit 0, print nothing the agent would read as a decision, and never block longer than the 2 s send timeout.

### Generalise (Claude-specific today)

- `agent`: `hooks/README.md` says "always `claude`". It should read `claude` | `codex`, required. Keep the core's `"claude"` default only as a fallback for old hooks.
- `warp://cli-agent`: a legacy title the core still accepts, read-only, for the official Warp plugin. Adapters MUST send `haunt://cli-agent`. Also legacy Warp are the `Unknown` names `permission_request`, `agent_needs_input`, `permission_replied` and `tool_complete`. Keep them as aliases in the core, but they are not part of the spec. `question_asked` and `stop_failure` are promoted into the table above.
- `plugin_version`: rename it to `adapter_version` in v2. For v1, keep the name and read it as "the adapter's version".
- `tool_count`: it means "todo items" on `todos_written` and "tool calls" on `subagent_result`. Leave it in v1. Give `todos_written` a `todo_count` in v2.
- `subagent_spawn.agent_type` default: Claude uses `general-purpose`, Codex `default`. The spec only requires it to equal the `agent_type` the agent later reports on `subagent_start`, because the core matches on that.
- `notification_type`: the values are Claude Code's (`permission_prompt`, `idle_prompt`). Other agents SHOULD reuse those two meanings rather than invent new ones.
- `plan_exit`, `task_*`, `question_answered` and `subagent_result` come from Claude tools. They are optional for other agents. Codex uses `todos_written` for its `update_plan`.

### Checking the core against it

Put one fixture file of spec lines, `spec/v1.jsonl`, in a shared place. A good place is the haunt repo, which both adapter repos vendor or point to. Then add:

- a `core/src/event.rs` test that parses every line and asserts it is not `EventKind::Unknown`. Until change 5 lands, `question_asked` and `stop_failure` are the allowed exceptions. That way nothing in the table falls into `Unknown` by accident.
- a check in each adapter's `tests/run.sh` that every event name it emits appears in the fixture
