# StreamAgent

A lightweight native Mac app that turns a 15-key Stream Deck into a local controller for apps, Codex agents, media, workspaces, and focus. macOS 14 or later. SwiftUI and AppKit; no third-party packages, browser runtime, account, server, or official Stream Deck software required.

## Controls

The physical left column is always:

| Key | Action |
| --- | --- |
| 0 · top left | Previous module |
| 5 · middle left | Show StreamAgent |
| 10 · bottom left | Next module |

Navigation wraps. The other twelve keys are the current page’s actions. Physical presses execute immediately; clicking a screen tile only selects it. Use **Run saved action** in the inspector to execute. Keyboard shortcuts also navigate modules: Option-Command-[ and Option-Command-].

The window uses the system appearance. Closing it leaves the menu bar and hardware active. The menu bar can show the window, select modules and custom pages, change Codex project banks, open Settings, or quit.

Key faces use Apple SF Symbols without name or status captions. Hardware artwork is rendered directly at the Original's **72×72 pixels**, with a 42-pixel maximum glyph extent, consistent medium weight, preserved proportions, and space around the glyph. The compact square Mac preview uses the same renderer and geometry, at the Mac display's Retina scale. Unused keys stay blank. Names remain in tooltips, VoiceOver, and the inspector; project names sit above the Mac preview, outside the key faces.

Ordinary actions use white symbols on a near-black display. The active module uses blue. Codex uses different shapes as well as semantic colors: rotating arrows for working, ellipsis for thinking, raised hand for waiting, checkmark for done, pause for idle, question mark for unknown, and warning triangle for failed. These choices follow Apple's [Icons](https://developer.apple.com/design/human-interface-guidelines/icons) and [SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols) guidance, adapted to the physical display rather than treating it as a small Mac window.

Codex keys have an 18-pixel project-color notch flush with the top-right edges, with a rounded inward corner. One, two, or three dark marks distinguish thread rows; status keeps its own central glyph. Colors persist across project reorder, banks, and app restarts. A matching dot appears by each project heading; its menu changes the color. The eight native colors repeat for larger project collections and can be reassigned. Names, project, and thread position remain accessible through tooltips and VoiceOver. Blank keys have no marker.

Keys reflect live context: running apps show a small dot; the current external app shows a check; selected timer duration is marked. Public CoreAudio notifications update output volume rings and the mute symbol where the output exposes those controls; unsupported readings remain unavailable. A lock marks actions needing Accessibility. Brief per-action badges mean pending, sent, or failed, then clear. They follow the action and destination rather than the slot after a page change. Press motion respects Reduce Motion; the device does not continuously animate or poll artwork.

## Modules

- **App Controls** follows the last external foreground app, including after StreamAgent becomes active. Finder, Safari, Chrome, VS Code, Xcode, and a general fallback have editable profiles. Select a key to edit its inspector name, SF Symbol, and action. Add a profile for the active app. While editing another profile, the screen explicitly identifies that profile; hardware icons and actions continue to use the live app’s profile. The preview’s Run button sends the saved preview action to the last external app. These are ordinary native shortcuts; StreamAgent does not recreate or claim private Touch Bar controls.
- **Codex** shows four project columns and three agent rows per bank. Each key represents one local chat through its status glyph. Tooltips and inspector prefer a saved chat name or agent nickname, with the full title retained in the inspector. Choose projects from the column headings, pin and reorder them, and use the toolbar or menu bar for more project banks. The threads menu accesses additional rows. Refreshes retain project and chat positions; new chats fill vacated positions. Clicking a key selects its details; **Open thread** or a physical press opens the bridge’s validated exact `codex://threads/<id>` link.
- **Media** sends real macOS play/pause, previous/next, mute, and volume key events. Playback depends on the app receiving system media controls; no track name or playback state is invented.
- **Workspaces** contains editable app, folder, file, and web launch tiles. Fresh defaults include the ordinary Applications folder. Existing user tiles are never migrated or replaced by new defaults.
- **Focus** runs a local start/pause/reset timer with 5, 15, 25, 45, and 60 minute tiles. The main key uses a remaining-time ring with play/pause/checkmark; exact time stays in the Mac window. Presets use native numeral-circle symbols; an hourglass represents one hour. Keep awake is optional in Settings and applies only while running. The timer uses elapsed wall time across sleep. It does not change Do Not Disturb or private system settings.

Add a custom module from the sidebar. Reorder modules with their contextual menu or list drag. Rename from the toolbar menu. Every module can have custom action pages; add, rename, reorder, and delete pages from that menu. Custom modules can also be deleted. Screen selection and editing never execute a tile.

The action editor supports keyboard shortcuts, opening an installed app, opening a file/folder/URL, and running a named Apple Shortcut. Paths can be chosen through a native panel. URL actions accept http, https, mailto, and codex schemes. There is no arbitrary shell action.

Opening files, links, apps, Shortcuts, Codex chats, and permission settings uses one background launch worker. If macOS stalls, the UI returns an error after five seconds and remains usable. The pending item may still open later. Further open requests fail with a busy message until macOS returns; retries never create more stuck workers. Module navigation, editing, and the local timer remain available.

## Install and build

Requires Xcode command line tools with a Swift 6 toolchain; the package compiles in Swift 5 language mode.

```sh
swift build --target StreamAgent
swift test
./scripts/package.sh
./scripts/verify.sh
```

The deliverable is **`dist/StreamAgent-macOS.zip`**, with `dist/StreamAgent-macOS.zip.sha256`. Packaging creates an original vector deck icon, cleans only the generated local staging bundle, signs it ad hoc, and archives it before copying anything into the synced workspace. This is a local development distribution, not a notarized release.

Quit StreamAgent yourself, then install outside synced Documents:

```sh
./scripts/install.sh
./scripts/verify.sh "$HOME/Applications/StreamAgent.app"
```

The installer defaults to the clean ZIP. It also accepts an archive or loose app path as its sole argument. It copies without resource forks or extended attributes into local temporary staging, verifies the candidate before replacing anything, then installs and verifies the exact `~/Applications/StreamAgent.app` path. An existing app is retained under `~/Applications/StreamAgent Backups/` with a unique name. A failed replacement restores the previous app. The installer refuses while any StreamAgent process is running; it never quits, launches the GUI, or changes user configuration. Open the installed app yourself when ready.

Default `./scripts/verify.sh` verifies the archive checksum when available, extracts the ZIP into local temporary storage, and checks its signature, system-only dynamic links, and non-GUI smoke result. Passing an explicit `.app` path verifies that exact app without altering it. Temporary verification files are removed afterward.

The loose `dist/StreamAgent.app` is a convenience copy. FileProvider can attach Finder metadata to apps under synced Documents after packaging, invalidating strict signature checks on that loose directory. Install from the ZIP; its signed contents remain intact. Moving or rebuilding an app may require reapproving Accessibility access. Do not run multiple device controllers at once.

```sh
"$HOME/Applications/StreamAgent.app/Contents/MacOS/StreamAgent" --smoke-test
"$HOME/Applications/StreamAgent.app/Contents/MacOS/StreamAgent" --diagnostics
```

Smoke testing exercises temporary configuration save/load, layout, and SF Symbol rendering, prints JSON, and exits without starting HID discovery, metadata polling, or a normal GUI session. Diagnostics reports configuration counts only, without titles or conversation content.

## Permissions and optional behavior

No permissions are requested automatically at startup. Keyboard and media actions check Accessibility access when run and show a clear error if it is missing. Open **Settings → Permissions → Open Accessibility settings**, grant access yourself, then retry. Keyboard posting activates the last external app, verifies it became foreground, and targets that process. If activation fails or the target exits, the action fails without sending the shortcut.

Files and Apple Shortcuts may need their own macOS permissions when used. Input Monitoring may be required by macOS for HID access on some systems; the connection status reports failures. Launch at login uses Apple’s `SMAppService` only after you enable it in Settings. Turn it off there to unregister. Auto-switching to App Controls and keep-awake are separate, reversible options; both default off. StreamAgent never modifies OS security settings.

## Configuration and recovery

Configuration is stored as validated JSON at:

```text
~/Library/Application Support/StreamAgent/configuration.json
```

Configuration has a 5,000,000-byte limit for both loading and canonical saved JSON. Oversized saves, exports, recovery writes, and imports are rejected before replacing existing bytes; compact imports must also fit after formatting. Changes use atomic replacement. Import and export use native file panels. Invalid imports leave the active configuration unchanged. Valid imports preserve a uniquely named copy of the previous configuration before replacement. A damaged startup file remains intact; temporary defaults are shown and normal saves are blocked. Export those defaults/edits, import a valid configuration, or use **Settings → Preserve damaged file and save** to keep a recovery copy and resume saving. Save failures remain visible; an in-memory edit is not proof that it reached disk.

## Status precision and privacy

Codex is read-only. Status is a heuristic based on durable local metadata, supported running-turn evidence, and bounded legacy event tails. “Thinking” means observed metadata for an open reasoning item, not access to the model’s private reasoning or proof it is currently computing. Stale or unreadable evidence becomes **Unknown**. **Done** reflects a completed observed turn, not completion of an entire project. **Waiting** reflects observed input/approval evidence. Missing data stays empty or unavailable; no sessions or progress are simulated.

The canvas shows human-readable counts and refresh age. Raw source diagnostics are available in Help’s Advanced section. Configuration does not copy Codex conversation content, credentials, or prompts.

## Extending modules

Module definitions and defaults live in `Sources/StreamAgent/Models.swift`; native action execution is in `Actions.swift`, board routing in `AppModel.swift`, and shared SF Symbol rendering in `DeckRenderer.swift`. Extend the typed action model, validation, editor, and execution together. Reserve physical keys 0, 5, and 10. Device image updates are diff-based: only changed symbols, tint, blank state, progress ring, corner identity, state badges, or press feedback repaint keys. Name/caption changes never send pixels. Timer rings use sixty discrete steps; output volume uses twenty. A reconnect deliberately repaints the device.

Tests cover fixed navigation and cell mapping, wrapping, stable Codex banks/rows, configuration recovery/import safety, action validation, live-versus-edited profile routing, rendering diffs, focus transitions, and blocked OS launches (main-thread responsiveness, timeout, bounded retries, late/duplicate callbacks, and all launch routes). Native window behavior, permission-granted keyboard/media delivery, login registration, Codex link handling, and physical key/visual confirmation require interactive QA on the installed app and device.

## Verification limits

Native QA has confirmed ordinary folder opening (including `~/Applications`), Finder profile switching, focus start/pause/reset, custom-tile save/relaunch, and a responsive UI with a five-second error during a stalled OS launch. Local Codex project/chat metadata and device image-report writes have been observed.

Opening this host’s protected/FileProvider Documents folder has been delayed in macOS sandbox-extension handling. The background launch timeout prevents a UI freeze; it cannot force macOS to finish that request. This differs from the confirmed ordinary-folder path.

Keyboard shortcuts and media keys require Accessibility access. The missing-permission error is verified; permission-granted delivery remains an interactive check. Physical key presses have reached the app counter; specific physical actions, displayed-image orientation, and unplug/replug behavior still require human confirmation. Exact Codex destination navigation and launch-at-login approval also remain interactive acceptance checks. Native screenshots have confirmed project-header alignment.
