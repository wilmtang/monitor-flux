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
        /// Actions whose media combo collides with another action's — only one can win the
        /// route (last assignment), so both are flagged for the same "already used" warning the
        /// Carbon path surfaces, rather than one silently shadowing the other.
        var mediaConflicts: Set<HotKeyAction> = []
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

        // Collect every media assignment first — the built-in defaults for un-bound actions,
        // then the recorded customs — so a shortcut claimed by two actions can be spotted.
        var mediaAssignments: [(shortcut: MediaKeyShortcut, action: HotKeyAction)] = []
        for action in HotKeyAction.allCases where isActive(action) {
            guard bindings[action.rawValue] == nil,
                  let shortcut = action.mediaShortcut
            else {
                continue
            }
            mediaAssignments.append((shortcut, action))
        }

        for (key, binding) in bindings {
            guard let action = HotKeyAction(rawValue: key), isActive(action) else { continue }
            switch binding {
            case .disabled:
                continue
            case .keyboard(let shortcut):
                maps.carbon[action] = shortcut
            case .media(let shortcut):
                mediaAssignments.append((shortcut, action))
            }
        }

        // Build the media route, flagging any combo claimed by more than one action.
        var owner: [MediaKeyShortcut: HotKeyAction] = [:]
        for (shortcut, action) in mediaAssignments {
            if let existing = owner[shortcut], existing != action {
                maps.mediaConflicts.insert(existing)
                maps.mediaConflicts.insert(action)
            }
            owner[shortcut] = action
        }
        maps.media = owner
        return maps
    }
}
