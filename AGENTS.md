Commit identity: thekozugroup <thekozugroup@gmail.com>. Never add AI co-author tags.

Use concise communication. Explain user impact in simple terms before technical details.

Native macOS app: SwiftUI/AppKit, IOKit, SF Symbols. No web runtime or Elgato software dependency.

Key faces are icon-only Apple SF Symbols on a dark 72×72 hardware canvas. No name/status captions. Preserve symbol proportions and consistent weight/padding. Mac preview shares the renderer at display scale; names remain in tooltips, VoiceOver, and inspector. Distinguish states by glyph as well as color.

Preserve fixed physical navigation keys 0, 5, 10. Never assign actions to these positions.

Codex integration is read-only. Never write Codex state or store credentials/prompts in app configuration, logs, fixtures, or delivery evidence. Status claims must match observed evidence.

Run swift test and scripts/package.sh + scripts/verify.sh for release changes. Keep working.md current; record exact committed artifact and native/hardware verification limits.
