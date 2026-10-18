import Foundation

extension DeckRenderer {
    static func contextualPresentation(for action: ActionTile, focus: FocusState,
                                       context: KeyContextSnapshot, targetBundle: String) -> DeckTilePresentation {
        var tile = presentation(for: action, focus: focus)
        guard !tile.isEmpty else { return tile }
        switch action.action.kind {
        case .openApp:
            let bundleID = ApplicationIdentity.bundleID(for: action.action.value)
            if bundleID == targetBundle, let bundleID, context.runningBundleIDs.contains(bundleID) {
                tile.tint = .blue; tile.accessory = .selected; tile.subtitle = "Active app"
            } else if let bundleID, context.runningBundleIDs.contains(bundleID) {
                tile.accessory = .running; tile.subtitle = "Running"
            }
        case .keyboard:
            tile.subtitle = targetBundle == "*" ? "Choose an app to control" : "Controls \(targetBundle)"
            if targetBundle == "*" { tile.dimmed = true }
            if !context.accessibilityGranted {
                tile.accessory = .locked; tile.dimmed = true
                tile.subtitle = "Accessibility access required"
            }
        case .media:
            let audio = context.audio
            if ["volumeUp", "volumeDown", "mute"].contains(action.action.value) {
                if let volume = audio.volume, volume.isFinite {
                    let level = min(1, max(0, volume))
                    tile.progress = (level * 20).rounded() / 20
                    tile.subtitle = "\(audio.name.isEmpty ? "Output" : audio.name) · \(Int((level * 100).rounded()))%"
                } else { tile.subtitle = audio.name.isEmpty ? "Output level unavailable" : audio.name }
                if let muted = audio.muted, action.action.value == "mute" {
                    tile.symbol = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
                    tile.tint = muted ? .amber : .neutral
                    tile.accessory = muted ? .selected : .none
                    tile.subtitle += muted ? " · Muted" : " · Sound on"
                }
            }
            if !context.accessibilityGranted {
                tile.dimmed = true; tile.accessory = .locked
                tile.subtitle += tile.subtitle.isEmpty ? "Accessibility access required" : " · Accessibility access required"
            }
        case .focus:
            if let minutes = Int(action.action.value), Int(focus.duration / 60) == minutes {
                tile.tint = .purple; tile.accessory = .selected; tile.subtitle = "Selected duration"
            }
            if action.action.value == "reset", focus.phase == .ready { tile.dimmed = true; tile.subtitle = "Timer already reset" }
        default: break
        }
        return tile
    }
}
