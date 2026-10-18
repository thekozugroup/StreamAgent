# StreamAgent

Native, local Mac controller for 15-key Stream Deck. SwiftUI/AppKit, IOKit HID, SF Symbols. No Elgato runtime, browser runtime, account, server, or third-party runtime dependency.

## Acceptance

- Left physical column is always previous module / current module icon / next module (indices 0,5,10). Other 12 keys are module content.
- Direct HID connection, reconnect, brightness, images, press/release handling. Both 2017 0x0060 and connected 2019 0x006D protocols.
- App Controls page changes actions with frontmost app; configurable profiles and safe native keyboard actions.
- Codex board: 4 projects x 3 agents, icon-only status faces, names in tooltips/inspector, press to open exact local thread. More projects reachable by bank. Status evidence honest, unavailable states explicit.
- Media, Workspaces, Focus pages; editable actions and custom pages; persistent local configuration, import/export.
- Native window and menu bar. All icons SF Symbols. Keyboard/accessibility support.
- Executable tests, packaged app launch, live Codex metadata read, real HID image-write evidence. Physical press/visual confirmation reported separately if unavailable.
- Review/fix loop, docs, reproducible app package, commit as thekozugroup@gmail.com. Push only if repository remote exists.

## Intent fidelity

Full requested device/page/agent scope retained. Desktop UI implementation + TDD convergence library patterns used. Independent transport, Codex bridge, app work delegated in parallel; integration/review/release gates follow. User requested noninteractive yolo; no breakpoints.

## Current

Icon-only redesign implemented and independently reviewed. Hardware uses 72×72 Apple SF Symbol artwork without captions; compact square Mac preview shares the renderer at Retina scale. Names remain in tooltips, VoiceOver, and inspector. Native candidate, 72 tests, release build, and package checks passed. Exact committed/installed delivery evidence belongs in ignored `dist/delivery.json`. Babysitter run `01M568661SBNZM3WNWAGCHE6R0` tracks delivery.

- After unlock, the earlier final candidate installed cleanly and native screenshot confirmed project headings align with the four key columns. Connection and 509 live chats remained available. The previously running build had received 15 key presses; no specific physical action/orientation claim follows from the counter alone.
- Design adaptation follows Apple's HIG Icons and SF Symbols guidance: recognizable standard metaphors, consistent medium weight, preserve aspect ratio, strong contrast, accessible alternate descriptions. Each glyph fits a centered 42-pixel region; status uses shape plus semantic color. Blank positions have no placeholder artwork. Timer uses an icon/ring; preset duration symbols are essential controls, not captions. Review repaired ambiguous workspace icons, generic timer presets on custom pages/profiles, and custom-name retention.
- Native redesign QA: caption-free square faces and crisp Retina symbols inspected in Workspaces, Media, Focus, and Codex. Agent identity inspected outside key faces; project bank forward/back retained positions. Timer start/countdown/pause/reset passed. Main device connection persisted across module changes. Physical-screen orientation/legibility still needs human confirmation.

- Hardware: actual 0x006D device accepted all 15 key images + brightness, 40 successful reports. 23 transport tests passed. Earlier running candidates' native input counters showed 15 and 2 presses, but specific physical actions/orientation and unplug/replug were not witnessed.
- Codex: live read of 509 chats / 30 projects in 59 ms; 493 friendly labels. 20 bridge tests passed. Durable metadata supports working/thinking/done/idle/failed/unknown. Modern SQLite cannot prove waiting; stale running evidence becomes Unknown after 120 seconds.
- App: five built-in modules, custom modules/pages, editable profiles/actions, stable agent banks, menu bar, local configuration recovery, packaging. Full suite: 72 tests passed after all repairs.
- Native UI: launched package, verified connection, Codex columns/statuses, Focus start/pause/reset, custom tile editing and save. Exact Codex URL accepted; destination app UI inspection is unavailable through CUA's safety restriction.
- Native QA found and repaired a real blocker: synchronous NSWorkspace.open blocked the main thread in macOS sandbox extension issuance. Launches now run off main with a five-second deadline and one pending OS call. Native responsiveness and timeout alert verified. Ordinary Applications folder delivery confirmed in Finder, and Finder-specific controls updated correctly. Protected/FileProvider Documents still waits inside macOS; no claim of successful protected-folder delivery.
- Independent review found and repaired: unequal heading/key columns (now shared grid), save/load size mismatch (now identical 5,000,000-byte limits before mutation), and synced bundle signature contamination (now clean staged signed ZIP + verified installer).
- Clean archive checksum, strict signature, system-only dependencies, and smoke check passed. ZIP is the immutable deliverable; synced loose app is only a convenience copy. Installer refuses while an app runs and preserves prior installed versions.
- Installed native app: `~/Applications/StreamAgent.app`. Installer preserved earlier candidates and user configuration. Desktop lock was cleared manually by the user; no security settings were changed.
- Private remote: https://github.com/thekozugroup/StreamAgent. Commit/push identity: thekozugroup <thekozugroup@gmail.com>. Final source SHA, artifact hashes, and exact installed verification are recorded in ignored `dist/delivery.json` after commit/rebuild.
