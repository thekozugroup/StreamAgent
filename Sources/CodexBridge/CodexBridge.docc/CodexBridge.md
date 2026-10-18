# Codex desktop metadata bridge

Implemented for Swift language mode 5 / macOS 14. Read-only local SQLite3; no app-server launch, network, account/config/auth access, log-body inspection, or private write API.

## Inspected sources — 2026-10-17

The installed desktop is `/Applications/ChatGPT.app`, bundle `com.openai.codex`, version `26.1007.71326` (build `20398`). Its bundled `codex-cli/codex-package.json` reports `0.162.0-alpha.17.2`. Inspection read the package descriptor, Info.plist, ASAR source, and database schema/status metadata. No second process/server was launched.

Both `~/.codex/state_5.sqlite` and `~/.codex/sqlite/state_5.sqlite` exist. The primary desktop database contains `threads.history_mode = 'paginated'`; that mode uses SQLite history, just as mode `sqlite` does. The older nested schema lacks `history_mode`. The reader discovers numbered `state_*.sqlite` and `thread_history_*.sqlite` in both locations, prefers root metadata for duplicate thread IDs, and prefers colocated/newest history databases. It never falls back from a SQLite-mode thread to a stale JSONL file.

Actual schema evidence:

- `threads`: `id`, `cwd`, `title`, `updated_at`, `updated_at_ms`, `archived`, `rollout_path`; optional `name`, `agent_nickname`, `history_mode`, `project_id`. The two inspected schemas differ, so optional columns are detected with `PRAGMA table_info`.
- `projects(id, name)` and `project_roots(project_id, position, path)` identify projects spanning multiple working directories.
- `thread_turns(thread_id, turn_id, rollout_ordinal, status, started_at, completed_at)`. Observed statuses: `inProgress`, `completed`, `interrupted`, `failed`. Times are Unix seconds.
- `thread_items(thread_id, turn_id, item_type, rollout_ordinal, updated_at_ordinal, created_at_ms, started_at_ms, completed_at_ms)`. Item times are milliseconds. Observed types include `reasoning`, `commandExecution`, `mcpToolCall`, `agentMessage`, `userMessage`, `fileChange`, and `webSearch`. The bridge never selects `item_json` or `error_json`.
- Native indexes `idx_thread_turns_page(thread_id, rollout_ordinal)`, `idx_thread_items_by_turn_updated_page(thread_id, turn_id, updated_at_ordinal)`, and `idx_threads_updated_at_ms(updated_at_ms DESC, id DESC)` bound the normal query paths. `EXPLAIN QUERY PLAN` confirmed indexed thread-specific history searches.

ASAR evidence, paths relative to `/Applications/ChatGPT.app/Contents/Resources/app.asar`. Offsets are character offsets within the decoded bundled JS, tied to the installed version above:

- `.vite/build/src-CP7XXlpZ.js`, offset 19987: constructs `codex://threads/${threadId}`. `webview/assets/agent-activity-item-fc85924771d9.js`, offset 6169: opens that route with an encoded thread ID. Info.plist registers scheme `codex`. The bridge constructs that exact local route without opening it. It rejects malformed/reserved-looking path characters; it does not add a prompt parameter.
- `.vite/build/main-CwxgTOle.js`, offsets 218846–219100: handles `turn/started` and `turn/completed` notifications with turn ID/status.
- The same main bundle, offsets 216458 and 216527: checks `activeFlags` for `waitingOnUserInput` and `waitingOnApproval`.
- `.vite/build/src-DCNiwad_.js`, offset 419208: pending server requests include `item/permissions/requestApproval` and `item/tool/requestUserInput`. Offset 555225: pending request categories produce runtime waiting flags. These are runtime state; neither inspected history table exposes an authoritative pending-request queue.
- `webview/assets/realtime-voice-codex-status-signal-455176799815.js`, offsets 2647 and 3249: checks an `inProgress` turn and explicitly running tool items. The desktop can use richer runtime state than this metadata-only integration.
- `.vite/build/src-CP7XXlpZ.js`, offset 103285: legacy protocol event names include `exec_approval_request`, `apply_patch_approval_request`, and reasoning delta events. Legacy support selectively decodes event type, timestamps, IDs, blocking flags, and terminal status; it retains no message, content, arguments, output, or reasoning text. Protocol-shaped JSONL fixture support does not imply the modern desktop persists those notifications.

## Status contract and limits

| Status | Required evidence |
| --- | --- |
| working | Latest SQLite turn is `inProgress`, with turn start or an item timestamp within 120 seconds. Legacy: explicit start/tool/progress event during a known running turn. Thread update recency alone never qualifies. |
| thinking | Running SQLite turn whose newest item is an actual open `reasoning` item with a recent start and no completion. Legacy: actual reasoning delta or reasoning-item-start event during a running turn. Completed reasoning artifacts and configuration reasoning effort never qualify. |
| waiting | Explicit unresolved blocking approval/user-input request in supported legacy/protocol-shaped events. Request IDs are matched; multiple requests remain waiting until all resolve or the turn ends. Modern SQLite alone cannot establish this status. |
| done | Latest durable turn explicitly completed. |
| idle | Latest durable turn explicitly interrupted/aborted. No-history threads are unknown. |
| failed | Latest durable turn explicitly failed. Individual failed tool attempts do not make the whole turn failed. Error bodies are never read. |
| unknown | Missing, malformed, unsupported, outside scan limits, future/invalid timestamps, or running evidence older than 120 seconds. |

An active long-running tool or model stream can go unknown if the desktop has not persisted fresh timing evidence for two minutes. A real runtime approval/input wait may appear as working briefly and then unknown because the pending request is not persisted. Do not interpret absence of `thinking`/`waiting` as proof that no thread is reasoning/waiting. This bridge cannot certify process liveness or sub-second runtime state. Sleeping, model/tool execution, and runtime connection errors cannot be further distinguished without evidence unavailable here.

Default poll interval: three seconds, serial utility queue, main-thread publication. Scans use one two-second deadline, 60 ms SQLite busy waits, an 8 MiB SQLite row/string safety limit, at most two numbered databases of each kind per known directory, 256 newest unarchived threads per state source, 512 distinct threads total, one latest turn and 32 latest item metadata rows per thread. No history-table-wide aggregation or recursive rollout enumeration. Sources exceeding those bounds are incomplete by design; older active threads outside the metadata window can be omitted.

Legacy reads are restricted to regular `.jsonl` files within the supplied Codex home's `sessions/` or `archived_sessions/`, including symlink validation. At most 32 changed files per poll, 256 KiB/2048 records per tail, with a rotating cursor and size/mtime cache. A missing start/request outside the tail means unknown, not inferred activity. Cached running evidence ages on every refresh. Malformed records invalidate preceding status evidence. SQLite-mode threads never use this fallback. SQLite opens use only `SQLITE_OPEN_READONLY`, verify `sqlite3_db_readonly`, and observe live WAL data; they never change application rows or checkpoints. SQLite may coordinate readers using its normal shared-memory locks.

## Public API and ordering

`AgentStatus`, `AgentSession`, `AgentProject`, and `CodexMonitor` match the requested API. `AgentSession` additionally exposes `public let displayName: String`; its initializer ends with `displayName: String? = nil` for existing call sites. Metadata precedence: nonempty `threads.name`, then `agent_nickname`, then `title`. Whitespace-only candidates are skipped, but selected values and original titles are retained verbatim. No generated summaries. A database title itself can contain a long initial task label; the inspector owns display treatment. No first-user-message, preview, prompt-body, or reasoning-body columns are selected.

Projects use explicit project IDs where available, otherwise canonical full working-directory paths. Same leaf names never merge unrelated directories. Sessions retain their exact working directory. Initial project/session order is newest first with deterministic ID/path tie-breaks. Existing project and row order remains stable across recency/status refreshes; new entries append. Removal/archive/window eviction can remove slots. A new monitor reseeds order. The UI owns pins, four-by-three selection, and banks; status changes do not move keys.

## Verification

Run from the project root:

```sh
swift test --filter CodexBridgeTests --scratch-path /tmp/StreamAgent-CodexBridge-build
swift run --scratch-path /tmp/StreamAgent-CodexBridge-build CodexProbe --json
```

`CodexProbe` prints only project/thread counts, all seven status aggregate counts, scan duration, and sanitized schema-source diagnostics. No session/title/name/path/prompt data is serialized. Both text and `--json` output are supported. Fixture tests cover modern and legacy starts/completions/interruptions/failures, explicit reasoning/tool/input events, request matching, stable slots, exact name precedence, missing/malformed schemas, bounds, WAL reads, and unchanged fixture database/WAL bytes. Live probe aggregates are a point-in-time sample, not a release or physical-key certification.

Verified at 2026-10-17 21:11 EDT: 20 bridge tests passed with zero failures, including a real three-second poll followed by stop/publication suppression. The full package compiled while running the filtered bridge tests. Final `swift run ... CodexProbe --json` completed without build warnings: 509 threads, 30 projects, 493 distinct name labels; working 2, thinking 0, waiting 0, done 135, idle 7, unknown 360, failed 5. Scan duration: 59 ms. This sampled both state locations and the primary SQLite history database. The app owner's separate native launch repair remains outside bridge verification.
