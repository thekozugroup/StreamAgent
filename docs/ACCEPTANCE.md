# StreamAgent acceptance

StreamAgent provides five native controller modules and editable custom pages. The app talks directly to the Stream Deck and reads local Codex activity without an account, server, or Elgato runtime.

## Implemented

- Fixed left physical column: previous module, active-module icon/show app, next module. Twelve content keys. Module navigation wraps.
- App Controls follows the last external app, with editable default, Finder, Safari, Chrome, VS Code, and Xcode profiles. Edited-profile previews and physical live-profile labels/actions remain consistent.
- Codex presents four project columns and three agent/chat rows, stable positions, project selection/pinning/order, additional banks, friendly names, and exact validated local-chat links.
- Media controls, editable app/folder/URL/Apple Shortcut actions, Focus timer, optional keep-awake, custom modules/pages, menu bar, permissions help, and optional login registration.
- Local atomic configuration, validation, import backups, damaged-file preservation, and consistent save/load size limits.
- Apple SF Symbols without key captions. Hardware artwork is exactly 72×72, with proportional centered glyphs, consistent medium weight, and a 15-pixel inset. Mac preview shares the same renderer and square geometry at Retina scale. Unused keys stay blank; names remain in tooltips, VoiceOver, and inspector. Codex states differ by shape as well as color. Original native vector application icon.
- Focus has an icon and remaining-time ring; exact time remains in the Mac window. Duration presets use numeral SF Symbols and an hourglass for one hour, including on custom pages and live app profiles. Saved custom names remain accessible. Finder and Applications have distinct glyphs, including presentation of older generic defaults without rewriting configuration.
- Codex project colors persist across reorders, banks, and relaunch. A flush 18×18 top-right notch has an 8-pixel inward radius and one/two/three thread-row dots. Project headings show matching dots and a native palette menu. Center symbols retain status; empty cells remain blank.
- Context uses actual running-app notifications and public CoreAudio output controls. Running/current-app badges include applications selected by path. Volume/mute can be unknown; playback is never inferred. Focus presets mark the selected duration. Permission locks and brief per-action pending/sent/failed badges remain legible. Press motion respects Reduce Motion.
- Shortcut destinations are captured at key-down, checked again before delivery, and included in feedback identity on every page. Switching app or page cannot attach an earlier command's feedback to the new destination.

## Executable evidence

The repaired source passed **106 tests** and a release build. Coverage includes packet layout, input edges, image orientation, bounded/coalesced writes, reconnection replay, read-only WAL metadata, status freshness, stable board positions, fixed navigation, configuration preservation/size limits, focus transitions, and blocked launch deadlines. Design regressions cover caption-free pixels, aspect ratio and edge padding, distinct available status/duration glyphs, retained custom names, old workspace defaults, and skipping metadata-only HID redraws. New coverage checks corner pixels and dot counts, project-color persistence and old configuration decoding, callback teardown/output switching, unknown audio readings, queued shortcut destination capture, custom-page feedback isolation, and chosen application paths. Independent review found three context issues; each received a regression and repair.

The clean staged ZIP passed checksum, strict ad-hoc signature, macOS-only dynamic dependency checks, and the packaged non-GUI smoke check. The installer refuses replacement while StreamAgent runs, verifies staging before mutation, retains the previous app, and restores it if replacement fails. Source SHA and final artifact hashes belong in `dist/delivery.json`, generated after the final commit/build.

## Native and hardware evidence

- Actual connected Stream Deck Original (2019), VID 0x0FD9 / PID 0x006D, accepted images for all 15 keys and brightness: **40 successful HID reports**. The probe stopped cleanly. No firmware operations or official-software changes occurred.
- Native package launched and connected to the device. Local Codex probe observed **509 chats across 30 projects**, including 493 friendly labels; one measured scan took 59 ms.
- Native UI verified Focus start/pause/reset, custom tile editing and save, saved tile/module restoration after relaunch, clear missing-Accessibility feedback, ordinary folder delivery to Finder, and app-specific Finder controls.
- The original protected-folder launch freeze was sampled. The repair's five-second timeout and continued native interaction were verified. A delayed OS request cannot create an unbounded queue or freeze device controls.
- A clean installed candidate at `~/Applications/StreamAgent.app` passed strict signature and smoke checks after native launch. The synced loose app acquired Finder/FileProvider attributes; distribution uses the clean archive instead.
- After manual unlock, the icon-only native candidate was installed and visually inspected. Square faces have no captions, Retina symbols are crisp, workspace actions are distinguishable, project headings align with content columns, and agent names/statuses remain accessible through the inspector. Project bank forward/back and Focus start/countdown/pause/reset were exercised. The real device remained connected throughout module changes. Final committed artifact and installed-native receipt are recorded in `dist/delivery.json`.
- Context iteration: native screenshots confirmed rounded corner notches, thread dots, matching heading colors, blank empty keys, and readable locked media controls. Project color changed through its native menu, survived bank navigation and relaunch, then was restored. CoreAudio reported the current speaker output and level. Timer execution showed Action sent, counted down, switched modules without stray feedback, and reset. Seven saved modules, six profiles, and 50% brightness were retained. No OS privacy permissions were granted.

## Remaining acceptance boundaries

- Earlier installed builds' native counters showed 15 and then 2 received presses. The specific physical keys/actions were not observed. Actual device-screen orientation/legibility, unplug/replug, and real 2017/MK.2 hardware remain manual checks. Native preview and protocol tests do not replace physical-screen confirmation.
- Accessibility was not granted by automation. Successful keyboard/media delivery with that permission, launch-at-login registration, and arbitrary Apple Shortcuts remain user-controlled checks.
- Exact Codex URLs were accepted by macOS, but CUA disallowed inspecting the Codex destination app. Remote/cloud-only chats are outside the local metadata adapter.
- Modern Codex SQLite does not establish approval waiting. Thinking requires observed open reasoning-item metadata; stale running evidence becomes Unknown after 120 seconds. Done means the latest observed turn completed, not the entire project. Older chats outside the bounded metadata window may be omitted.
- This host's protected/FileProvider Documents opening remained delayed in macOS sandbox-extension handling. Ordinary local folder opening was confirmed. The app reports delayed requests without changing privacy settings.
- The package is an arm64 local development build, signed ad hoc, not notarized for public distribution.

## Reproduce

```sh
swift test
./scripts/package.sh
./scripts/verify.sh
# Quit StreamAgent before replacing the installed application.
./scripts/install.sh
./scripts/verify.sh "$HOME/Applications/StreamAgent.app"
.build/release/CodexProbe --json
.build/release/StreamDeckProbe --write --listen-seconds 10
```

Run the device probe only while StreamAgent and other controllers are closed. It changes the key images and brightness. Native manual checks must use the exact installed candidate; never infer them from the smoke check.
