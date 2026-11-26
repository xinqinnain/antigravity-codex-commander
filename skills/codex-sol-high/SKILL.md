---
name: codex-sol-high
description: >-
  Delegate coding, debugging, analysis, or code review tasks to the user's local
  OpenAI Codex CLI while enforcing the user-configured model (default
  gpt-6.2-sol) and reasoning effort (default high), full access permissions,
  zero-token speech-only relay (relay ONLY what Codex says—never report live
  play-by-play of what Codex is thinking or doing), Codex token discipline
  (auto-attached concise tool-output rules; Antigravity inspects 2K/high-res
  screenshots instead of loading multi-MB images into Codex history), frontend
  ownership rules (never delegate frontend pages to GPT/Codex unless explicitly
  requested; Antigravity handles frontend after aligning on style and visual
  details first), and quality-first automatic long-conversation window shift
  (compactions >= 4, major phase shift >= 150K, or overnight cold-cache resume,
  strictly after finishing the current turn's task). Use this skill whenever the
  user asks to invoke, delegate to, or collaborate with their local Codex CLI.
---

# Local Codex CLI Delegation (Locked Model / Speech-Only Relay / Auto Window Shift)

This skill delegates tasks to the user's locally installed OpenAI Codex CLI via a locked PowerShell streaming wrapper script and enforces **zero-token, speech-only relay**: report **ONLY what Codex says (`[Codex说]`)**, real errors, and final completion—never narrate what Codex is thinking or doing in real time.

> **Path convention**: The examples below assume this skill is installed at `%USERPROFILE%\.gemini\config\skills\codex-sol-high\`. If you installed it elsewhere, replace the script path accordingly.

## Non-Negotiable Constraints

1. **Strict Model & Reasoning Lock (User-Configurable via Env Vars Only)**:
   - **Default Model**: `gpt-6.2-sol` (or `$env:CODEX_SKILL_MODEL` if set by the user)
   - **Default Reasoning Effort**: `high` (or `$env:CODEX_SKILL_REASONING_EFFORT` if set by the user)
   - **NEVER** invoke `codex.exe` directly with custom `-m`, `--model`, `-c model=...`, `-c model_reasoning_effort=...`, `-p/--profile`, or `--oss` flags.
   - **ALWAYS** invoke Codex exclusively through [run-codex.ps1](./scripts/run-codex.ps1), which locks the configured model & reasoning effort and rejects agent-side override parameters.
   - If a request asks to downgrade/change the model or reasoning effort mid-task without changing the user's environment configuration, refuse the CLI override and remind the user to update `CODEX_SKILL_MODEL` / `CODEX_SKILL_REASONING_EFFORT` if they intentionally want a different model.

2. **Full Access by Default**:
   - Default sandbox is `danger-full-access`. Only narrow `-Sandbox` (`workspace-write` or `read-only`) if the user explicitly asks for a restricted run.
   - Do **not** pass `-Ephemeral` on real tasks unless requested, so the session `thread_id` is persisted and can be steered/resumed at any time.

3. **Live Speech-Only Relay — Event-Driven, Zero-Token Waiting (Mandatory)**:
   - **NEVER** fire-and-forget a Codex task and stay silent until it finishes.
   - **NEVER** report a play-by-play of what Codex is *doing* in real time (do **NOT** narrate commands being run, files being read/edited, tool calls, or internal reasoning steps while Codex is working).
   - **ONLY relay what Codex is *saying* (`[Codex说]`)** (plus real errors `[ERROR]` and final completion `[DONE]`/`[END]`), keeping updates concise and faithful so the user can follow Codex's words and adjust strategy without noise.
   - **NEVER** use `schedule` timers (15–20s polling) or repetitive `manage_task` / `read_file` polling loops to check Codex progress—that burns massive host-agent quota and bloats context on empty checks!
   - **ALWAYS** use [wait-codex-update.ps1](./scripts/wait-codex-update.ps1), which **hard-locks speech-only mode** (`mode=speech-only-locked`): it silently monitors `<live-log-path>` locally at 0 tokens and wakes you up **ONLY** when Codex actually says something (`[Codex说]`), errors (`[ERROR]`/`[STDERR]`), completes (`[DONE]`/`[END]`), or hits a 600s (10-minute) quiet heartbeat. Never try to bypass speech-only mode.

4. **Frontend Page Ownership & Pre-Design Alignment (Strict)**:
   - **NEVER** delegate frontend page / UI / visual interface development (pages, layouts, styling, components, animations, interactive web UIs) to Codex/GPT **unless the user explicitly states** that GPT/Codex should build the frontend page (e.g., "让 GPT 来做前端页面" / "让 Codex 做前端").
   - In mixed full-stack tasks without such an explicit override, delegate only non-frontend parts (e.g., backend, APIs, algorithms, CLI/tooling, debugging, review) to Codex, and **handle all frontend page development yourself**.
   - **Before building or redesigning any frontend page yourself**, you MUST first communicate with the user to align on the desired visual style, aesthetic direction, color palette/theme, layout hierarchy, interactive/visual details, and target devices — do not jump directly into coding the frontend without confirming these details first.

5. **Long-Conversation Window Shift (Quality-First Automatic Handoff — 3 Triggers)**:
   - Every persisted Codex session's compaction count, context size, and idle time are checked at zero token cost via [check-session-health.ps1](./scripts/check-session-health.ps1) (and auto-reported at the end of every `run-codex.ps1` turn).
   - **Mandatory Precondition (All Triggers)**: **NEVER** interrupt or shift windows in the middle of an unfinished turn/task (unless the user explicitly cancels/redirects the old direction). Finish and verify the current turn first.
   - **Automatic Hot Execution**: When a trigger fires, execute the handoff **automatically** (do NOT pause to ask the user—waiting >5 minutes lets the server prompt cache go cold) and inform the user in one concise sentence.
   - **Trigger 1 — Compaction Hard Shift (`compactions >= 4`, or `$env:CODEX_SKILL_COMPACTION_THRESHOLD`)**: Whenever `NeedsHandoffAfterTurn=true` (reported as `[HANDOFF_REQUIRED]`), after finishing the current turn, let the **old window write the handoff while its cache is hot**, then open a fresh window.
   - **Trigger 2 — Major Phase Transition (`PhaseShiftEligible=true` + Phase Boundary Signal)**:
     - **Volume Gate**: Only consider phase-shift handoff when `LastContextTokens >= 150,000` OR `CompactionCount >= 1` (`phase_shift_eligible=true`). Do NOT split light windows (`< 150K` and `0` compactions).
     - **Strong Phase-Transition Signals (hit ANY 1 after current turn is verified)**:
       1. *Explicit phase/milestone jump*: User or plan explicitly moves to a new phase (`Phase 1 → Phase 2`, `Step 1 → Step 2`, etc.).
       2. *Primary goal / KPI switch*: Core acceptance metric fundamentally changes (e.g., startup time / cache hits → 2K 120 FPS rendering; bug triage → new feature module).
       3. *Codebase zone switch*: Next turn touches a largely disjoint set of files/subsystems from the previous turn (~80% of old context no longer applies).
       4. *User hard-cancels old direction*: User stops/discards an old experiment line and pivots to a new goal.
     - **Explicit Non-Triggers (keep `resume`, do NOT shift)**: rework/tuning/bug-fixing within the same goal, sequential sub-steps inside the same phase, or light windows (`< 150K` and `0` compactions).
     - **Author**: Let the **old window write the handoff while hot** (zero detail loss).
   - **Trigger 3 — Overnight / Cold-Cache Resume (`CacheLikelyCold=true`: `IdleMinutes >= 10` AND `LastContextTokens > 150,000`)**:
     - Before calling `-Mode resume` after a break (`>= 10 min`), run `check-session-health.ps1 -SessionId <thread_id>` (0 tokens).
     - If **previous turn/phase was already completed & verified**: Do **NOT** wake the cold 150K+ old window—**Antigravity writes the handoff directly** from existing verification records + `git status/diff` + prior log summary, then starts a fresh `-Mode exec` window (saves ~150K–250K cold non-cache recompute with zero quality loss).
     - If **previous turn stopped mid-phase (unfinished work)**: **Preserve memory by default and continue `-Mode resume`**, UNLESS `ColdResumeHighPressure=true` (`LastContextTokens > 200,000` OR `CompactionCount >= 3`), in which case rotate cleanly to a fresh window.

6. **Codex Token Discipline — Concise Tool Output & Visual Inspection Ownership**:
   - **Auto-Attached Output Discipline**: Every `exec` and `resume` dispatch through [run-codex.ps1](./scripts/run-codex.ps1) automatically appends `[Codex 输出与审图纪律]`, instructing Codex NOT to dump raw large logs, entire large files, or broad `grep` outputs to stdout—instead filter key lines, read exact line ranges, or aggregate JSON/metrics via short scripts. Do not disable this unless explicitly asked.
   - **2K / High-Res Screenshot Inspection Owned by Antigravity**: By default, **Antigravity (you)** inspects 2K and high-resolution screenshots directly (via `read_file`). Do **NOT** pass multi-MB screenshots via `-Image` or ask Codex to read high-res PNGs into its long session history unless the user explicitly asks Codex to inspect an image. Instead, let Codex generate/save the screenshots and report their paths + numeric metrics, then inspect the images yourself.

7. **Account Safety Guardrails (ChatGPT Subscription Login)**:
   - Only run Codex on explicit user request during an active interactive session.
   - Do **not** run unattended loops, cron/scheduled polling, or high-concurrency bursts against a personal ChatGPT login.

## Live Relay Workflow (Event-Driven, Zero-Token Wait — Follow Strictly)

### Step 1: Launch Codex with a Known LogFile

Choose a dedicated transcript log path (e.g., `<ArtifactDir>/scratch/codex-live-<id>.log` or a unique path under `$env:LOCALAPPDATA\Temp\codex-sol-high\`) and run [run-codex.ps1](./scripts/run-codex.ps1) via `run_command` with `WaitMsBeforeAsync=5000`:

```powershell
pwsh -NoProfile -File "$env:USERPROFILE\.gemini\config\skills\codex-sol-high\scripts\run-codex.ps1" `
  -WorkDir "<target-dir>" `
  -LogFile "<live-log-path>" `
  -Prompt "<clear, self-contained task prompt>"
```

For multi-line or complex prompts, write the prompt to a UTF-8 file and pass `-PromptFile <path>`.

### Step 2: Arm the Zero-Token Event Watcher (Do NOT Use `schedule` Polling!)

If `run-codex.ps1` finishes synchronously within 5 seconds, immediately report Codex's full output and run Step 4.

If `run-codex.ps1` backgrounds into `<codexTaskId>`:

1. **Arm the local speech-only event watcher immediately** via `run_command` with `WaitMsBeforeAsync=500` (so it goes to background as `<watcherTaskId>` at 0 LLM token cost):
   ```powershell
   pwsh -NoProfile -File "$env:USERPROFILE\.gemini\config\skills\codex-sol-high\scripts\wait-codex-update.ps1" `
     -LogFile "<live-log-path>" `
     -AfterLine 0 `
     -DebounceSeconds 8 `
     -MaxWaitSeconds 600
   ```
   *(Hard-locked `speech-only` mode: completely ignores `[执行命令]`/`[命令完成]`/`[修改文件]`/`[工具调用]`/`[思考]` while Codex works; wakes up ONLY when Codex speaks (`[Codex说]`), hits `[ERROR]`/`[STDERR]`, finishes (`[END]` in 0s), or is silent for 600s / 10 minutes. If `run-codex.ps1` already emitted a `[Codex说]` line in its initial output, relay it right away and set `-AfterLine` accordingly; otherwise use `-AfterLine 0`.)*
2. Tell the user briefly that Codex has started in silent speech-only monitoring mode (only relaying what Codex says—do **not** say "实时播报" or "实时进展"), then **stop calling tools** and wait reactively.
3. **Every time `<watcherTaskId>` completes** (its output ALREADY contains `[WATCHER] status=<UPDATE|COMPLETED|HEARTBEAT> | mode=speech-only-locked | runner=<alive|exited> | next_line=<N> | ...` followed ONLY by Codex's `[Codex说]` / `[SESSION]` / `[ERROR]` / `[DONE]` lines—do **NOT** call `manage_task` or `read_file`!):
   - Record `thread_id` as soon as `[SESSION] thread_id=...` appears.
   - **If `status=UPDATE`**:
     1. Immediately re-arm the next watcher (`run_command`, `WaitMsBeforeAsync=500`) with `-AfterLine <next_line>`.
     2. In your reply right after arming the watcher, prefix with `**Codex 说**：` (never `**Codex 实时进展**：`) and **ONLY relay what Codex said (`[Codex说]`)** (or any `[ERROR]`) concisely and faithfully—do **NOT** narrate commands, tool calls, or file edits Codex is performing in the background. End your turn.
   - **If `status=HEARTBEAT`** (Codex has not spoken for 10 minutes while working silently):
     1. **NEVER call `manage_task` on `HEARTBEAT`** — `wait-codex-update.ps1` has ALREADY verified the runner PID is alive (`runner=alive`; if the process had died it would have immediately returned `status=COMPLETED`).
     2. Directly re-arm the next watcher (`run_command`, `WaitMsBeforeAsync=500`) with `-AfterLine <next_line>` (`MaxWaitSeconds=600`).
     3. Send at most a single brief line (e.g., "Codex 仍在后台执行，过去 10 分钟暂无新发言，继续静默监听中…") and end your turn.
   - **If `status=COMPLETED`**:
     - Do NOT arm another watcher. Proceed immediately to Step 4!
4. **If `<codexTaskId>` completes first** (before `<watcherTaskId>` returns):
   - Cancel `<watcherTaskId>` if still running (`manage_task(Action="kill", TaskId="<watcherTaskId>")`)—or let it auto-exit within ~0.5s since `[END]` was written—and proceed immediately to Step 4.

### Step 3: Steering / Strategy Adjustment Mid-Run

When the user replies mid-run to adjust strategy:

1. Kill the active watcher (`manage_task(Action="kill", TaskId="<watcherTaskId>")`) if still running.
2. **Hard redirect (default & most immediate)**:
   - Kill the running Codex background task (`manage_task(Action="kill", TaskId="<codexTaskId>")`).
   - Immediately resume the exact same Codex conversation with the user's new instructions and a fresh log file:
     ```powershell
     pwsh -NoProfile -File "$env:USERPROFILE\.gemini\config\skills\codex-sol-high\scripts\run-codex.ps1" `
       -Mode resume `
       -SessionId "<thread_id>" `
       -WorkDir "<target-dir>" `
       -LogFile "<new-live-log-path>" `
       -Prompt "<user's adjusted strategy>"
     ```
   - Restart the Step 2 event watcher loop.
3. **Soft queue (only if the user explicitly says "don't stop it, just queue this next")**:
   ```powershell
   pwsh -NoProfile -File "$env:USERPROFILE\.gemini\config\skills\codex-sol-high\scripts\run-codex.ps1" `
     -Mode queue `
     -SessionId "<thread_id>" `
     -WorkDir "<target-dir>" `
     -Prompt "<follow-up instruction>"
   ```
   Then re-arm `wait-codex-update.ps1` if the watcher was stopped.

### Step 4: Completion, Verification & Post-Turn Window Shift Check

When `<codexTaskId>` finishes (or watcher reports `status=COMPLETED`):
1. If any trailing lines were not yet shown by the watcher (e.g., `<codexTaskId>` completed before watcher reported), read only the unread tail from `<live-log-path>` (`StartLine = lastLine + 1`).
2. Relay Codex's final message (`[Codex说]`), token summary (`[DONE]`), `thread_id`, and any modified files.
3. Inspect `git diff` / modified files to verify that **this turn's task is genuinely complete**.
4. Check the `[HEALTH]` / `[HANDOFF_REQUIRED]` line at the end of the output (or run [check-session-health.ps1](./scripts/check-session-health.ps1) with `-SessionId <thread_id>`):
   - If `[HANDOFF_REQUIRED]` (`compactions >= 4`): once this turn's task is verified complete, **automatically** run the **Window Shift Procedure (Hot Path)** before starting the next turn.
   - If `[HEALTH]` shows `phase_shift_eligible=true` (`LastContextTokens >= 150K` or `compactions >= 1`) **AND** the next task crosses a **Major Phase Transition** (any of the 4 strong signals in Constraint #5): **automatically** run the **Window Shift Procedure (Hot Path)** right now while the old window's cache is still hot.
   - Otherwise (`compactions < 4` and continuing within the same phase): keep the current `thread_id` for future `resume` turns (if resuming after a `>= 10 min` gap, check `check-session-health.ps1` first for Trigger 3 cold-cache handling).

## Window Shift Procedure (窗口换班标准流程)

Execute automatically (no need to pause for confirmation) when Trigger 1 (`compactions >= 4`), Trigger 2 (Major Phase Transition with `>= 150K` or `compactions >= 1`), or Trigger 3 (Cold-Cache Resume) fires—strictly after confirming the current turn is finished (or explicitly cancelled by the user):

1. **Choose Persistent Handoff Path**: Prefer `<ArtifactDir>/scratch/codex-handoff-<timestamp>.md` so the user's git working tree stays clean (unless the user asks to store it inside the repo).
2. **Generate Structured Handoff Following [handoff-template.md](./resources/handoff-template.md)**:
   - **Hot Path (Trigger 1 / Trigger 2, idle `< 5 min`)**: Immediately run one final `-Mode resume -SessionId <old_thread_id>` while prompt cache is hot, instructing Codex to write the complete handoff document (core goal & acceptance criteria, completed work & verified results, current codebase/environment state, **approaches tried that failed and why ("试过但没走通的方案与原因")**, hard constraints, and exact next 1–3 steps). Read it to verify accuracy.
   - **Cold Completed-Phase Path (Trigger 3, `CacheLikelyCold=true` & previous phase already verified)**: Do **NOT** `resume` the cold old window. **Antigravity writes the handoff document directly** from verified turn deliverables, prior log tail, and `git status` / `git diff` (saving 150K–250K cold non-cache input).
3. **Retire Old Session & Onboard Fresh Window (`-Mode exec`)**:
   - Mark `<old_thread_id>` as retired—**do NOT `resume` it for future tasks**.
   - Start a **brand-new** Codex session via `run-codex.ps1 -Mode exec` (do NOT pass `-SessionId` or `-Last`), passing the handoff document (or instructing the new window to read it first) alongside the next turn's task.
   - Inform the user in one concise line why the shift happened (e.g., `compactions=4` / `大阶段切换且上下文 165K` / `隔夜已结项冷缓存重续`), report the new `thread_id`, and continue the Step 2 speech-only watcher loop.

### Checking Session Health Manually (Zero Tokens)

```powershell
# Check one specific session
pwsh -NoProfile -File "$env:USERPROFILE\.gemini\config\skills\codex-sol-high\scripts\check-session-health.ps1" -SessionId "<thread_id>"

# Inspect the 10 most recent local Codex sessions
pwsh -NoProfile -File "$env:USERPROFILE\.gemini\config\skills\codex-sol-high\scripts\check-session-health.ps1" -Top 10
```

## Script Modes & Flags

- `-Mode exec` (default) | `review` | `resume` | `queue`
- `-Sandbox danger-full-access | workspace-write | read-only` (default: `danger-full-access`)
- `-LogFile <path>` — live UTF-8 transcript file (auto-created under `%LOCALAPPDATA%\Temp\codex-sol-high\` if omitted; file share allows concurrent `read_file` while Codex writes)
- `-PromptFile <path>` — read prompt from UTF-8 file
- `-OutputLastMessage <file>` — save Codex's final message to a file
- `-RawJson` — emit raw JSONL instead of formatted Chinese progress lines
- `-Ephemeral` — do not persist session (avoid if you may want to steer/resume)
- `-Worktree`, `-Image <file>...`, `-AddDir <dir>...`, `-ApproveForMe`, `-DryRun`, `-NoDispatchDiscipline`
- Review flags: `-Uncommitted`, `-Base <branch>`, `-Commit <sha>`, `-Title <title>`
- Resume/Queue flags: `-SessionId <uuid>`, `-Last`, `-All`
