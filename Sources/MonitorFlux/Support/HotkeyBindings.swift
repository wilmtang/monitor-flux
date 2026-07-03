import Foundation

/// Pure derivation of the active shortcut maps from the saved bindings, extracted from
/// `AppStore.refreshHotKeys` so the resolution rules are unit-testable: which actions keep
/// their built-in media-key defaults, which carry custom Carbon or media combos, what a
/// `.disabled` binding suppresses, and how the fine-adjustments master gates the ⌥ variants.
enum HotkeyBindings {
    struct Maps: Equatable {
        /// Custom keyboard combos to register as Carbon hot keys.
        var carbon: [HotKeyAction: GlobalShortcut] = [:]
        /// Media-key combos the event tap should route, including the un-overridden defaults.
        var media: [MediaKeyShortcut: HotKeyAction] = [:]
    }

    static func maps(
        bindings: [String: ShortcutBinding],
        fineAdjustmentsEnabled: Bool
    ) -> Maps {
        var maps = Maps()
        // With fine adjustments off, fine actions register nothing at all — neither their
        // ⌥ defaults nor recorded customs — so every ⌥ media combo stays with macOS.
        let isActive: (HotKeyAction) -> Bool = { action in
            !action.isFine || fineAdjustmentsEnabled
        }

        for action in HotKeyAction.allCases where isActive(action) {
            guard bindings[action.rawValue] == nil,
                  let shortcut = action.mediaShortcut
            else {
                continue
            }
            maps.media[shortcut] = action
        }

        for (key, binding) in bindings {
            guard let action = HotKeyAction(rawValue: key), isActive(action) else { continue }
            switch binding {
            case .disabled:
                continue
            case .keyboard(let shortcut):
                maps.carbon[action] = shortcut
            case .media(let shortcut):
                maps.media[shortcut] = action
            }
        }
        return maps
    }
}
