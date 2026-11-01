# Proposed haunt core changes for Codex rows

These are proposals only; none of them is applied. File and line references are to haunt `master` at `2c026a1` plus the uncommitted work in progress. The adapter already works against today's core for status, progress, subagents and verified requests. Without change 3, though, answering a Codex prompt from haunt is wrong.

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
