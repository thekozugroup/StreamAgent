# StreamAgent acceptance

StreamAgent provides five native controller modules and editable custom pages. The app talks directly to the Stream Deck and reads local Codex activity without an account, server, or Elgato runtime.

## Implemented

- Fixed left physical column: previous module, active-module icon/show app, next module. Twelve content keys. Module navigation wraps.
- App Controls follows the last external app, with editable default, Finder, Safari, Chrome, VS Code, and Xcode profiles. Edited-profile previews and physical live-profile labels/actions remain consistent.
- Codex presents four project columns and three agent/chat rows, stable positions, project selection/pinning/order, additional banks, friendly names, and exact validated local-chat links.
- Media controls, editable app/folder/URL/Apple Shortcut actions, Focus timer, optional keep-awake, custom modules/pages, menu bar, permissions help, and optional login registration.
- Local atomic configuration, validation, import backups, damaged-file preservation, and consistent save/load size limits.
- SF Symbols throughout the interface and key images. Original native vector application icon.

## Executable evidence

The repaired source passed **67 tests** and a release build. Coverage includes packet layout, input edges, image orientation, bounded/coalesced writes, reconnection replay, read-only WAL metadata, status freshness, stable board positions, fixed navigation, configuration preservation/size limits, focus transitions, and blocked launch deadlines.

The clean staged ZIP passed checksum, strict ad-hoc signature, macOS-only dynamic dependency checks, and the packaged non-GUI smoke check. The installer refuses replacement while StreamAgent runs, verifies staging before mutation, retains the previous app, and restores it if replacement fails. Source SHA and final artifact hashes belong in `dist/delivery.json`, generated after the final commit/build.

## Native and hardware evidence

- Actual connected Stream Deck Original (2019), VID 0x0FD9 / PID 0x006D, accepted images for all 15 keys and brightness: **40 successful HID reports**. The probe stopped cleanly. No firmware operations or official-software changes occurred.
- Native package launched and connected to the device. Local Codex probe observed **509 chats across 30 projects**, including 493 friendly labels; one measured scan took 59 ms.
- Native UI verified Focus start/pause/reset, custom tile editing and save, saved tile/module restoration after relaunch, clear missing-Accessibility feedback, ordinary folder delivery to Finder, and app-specific Finder controls.
- The original protected-folder launch freeze was sampled. The repair's five-second timeout and continued native interaction were verified. A delayed OS request cannot create an unbounded queue or freeze device controls.
- A clean installed candidate at `~/Applications/StreamAgent.app` passed strict signature and smoke checks after native launch. The synced loose app acquired Finder/FileProvider attributes; distribution uses the clean archive instead.

## Remaining acceptance boundaries

- Final shared-grid alignment is implemented; its final native visual check and candidate upgrade were waiting for the desktop to be unlocked at the last recorded checkpoint. Earlier native screenshots exposed the original alignment defect. Do not treat source geometry alone as final visual proof.
- Physical key presses, actual device screen orientation, unplug/replug, and real 2017/MK.2 hardware were not observed. Protocol and reconnect tests do not replace those checks.
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
