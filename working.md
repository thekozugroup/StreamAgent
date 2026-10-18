# StreamAgent

Native, local Mac controller for 15-key Stream Deck. SwiftUI/AppKit, IOKit HID, SF Symbols. No Elgato runtime, browser runtime, account, server, or third-party runtime dependency.

## Acceptance

- Left physical column is always previous module / current module icon / next module (indices 0,5,10). Other 12 keys are module content.
- Direct HID connection, reconnect, brightness, images, press/release handling. Both 2017 0x0060 and connected 2019 0x006D protocols.
- App Controls page changes actions with frontmost app; configurable profiles and safe native keyboard actions.
- Codex board: 4 projects x 3 agents, status labels and symbols, press to open exact local thread. More projects reachable by bank. Status evidence honest, unavailable states explicit.
- Media, Workspaces, Focus pages; editable actions and custom pages; persistent local configuration, import/export.
- Native window and menu bar. All icons SF Symbols. Keyboard/accessibility support.
- Executable tests, packaged app launch, live Codex metadata read, real HID image-write evidence. Physical press/visual confirmation reported separately if unavailable.
- Review/fix loop, docs, reproducible app package, commit as thekozugroup@gmail.com. Push only if repository remote exists.

## Intent fidelity

Full requested device/page/agent scope retained. Desktop UI implementation + TDD convergence library patterns used. Independent transport, Codex bridge, app work delegated in parallel; integration/review/release gates follow. User requested noninteractive yolo; no breakpoints.

## Current

Implementation and review repairs complete. Independent source/archive review passed with zero remaining findings. Final delivery gate waits for the unlocked desktop. Babysitter run `01M568661SBNZM3WNWAGCHE6R0`.

- Hardware: actual 0x006D device accepted all 15 key images + brightness, 40 successful reports. 23 transport tests passed. Physical press/orientation and unplug/replug not observed.
- Codex: live read of 509 chats / 30 projects in 59 ms; 493 friendly labels. 20 bridge tests passed. Durable metadata supports working/thinking/done/idle/failed/unknown. Modern SQLite cannot prove waiting; stale running evidence becomes Unknown after 120 seconds.
- App: five built-in modules, custom modules/pages, editable profiles/actions, stable agent banks, menu bar, local configuration recovery, packaging. Full suite: 67 tests passed after all repairs.
- Native UI: launched package, verified connection, Codex columns/statuses, Focus start/pause/reset, custom tile editing and save. Exact Codex URL accepted; destination app UI inspection is unavailable through CUA's safety restriction.
- Native QA found and repaired a real blocker: synchronous NSWorkspace.open blocked the main thread in macOS sandbox extension issuance. Launches now run off main with a five-second deadline and one pending OS call. Native responsiveness and timeout alert verified. Ordinary Applications folder delivery confirmed in Finder, and Finder-specific controls updated correctly. Protected/FileProvider Documents still waits inside macOS; no claim of successful protected-folder delivery.
- Independent review found and repaired: unequal heading/key columns (now shared grid), save/load size mismatch (now identical 5,000,000-byte limits before mutation), and synced bundle signature contamination (now clean staged signed ZIP + verified installer).
- Clean archive checksum, strict signature, system-only dependencies, and smoke check passed. ZIP is the immutable deliverable; synced loose app is only a convenience copy. Installer refuses while an app runs and preserves prior installed versions.
- Earlier installed candidate is running at `~/Applications/StreamAgent.app`. Final candidate reinstall/visual alignment verification waits for an unlocked Mac: CUA reported automatic unlock failed. User was asked to unlock; no security settings or running process were changed to bypass the lock.
- Private remote created: https://github.com/thekozugroup/StreamAgent. Commit/push identity: thekozugroup <thekozugroup@gmail.com>. Final source SHA and artifact hashes will be recorded in ignored `dist/delivery.json` after commit/rebuild.
