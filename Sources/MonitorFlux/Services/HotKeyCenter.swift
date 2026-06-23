import Carbon.HIToolbox
import Foundation

/// Registers the user's custom global shortcuts with Carbon's `RegisterEventHotKey` and
/// routes presses to `onAction`. Carbon hot keys fire system-wide without intercepting every
/// keystroke (unlike an event tap), so they're the safe way to add user-assignable shortcuts
/// on top of the media-key tap. Carbon delivers presses on the main event target, so this is
/// `@MainActor`.
@MainActor
final class HotKeyCenter {
    /// Invoked on the main thread when a registered shortcut is pressed.
    var onAction: ((HotKeyAction) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var actionsByID: [UInt32: HotKeyAction] = [:]
    private var eventHandler: EventHandlerRef?
    // 'MFlx' — a four-char signature so our hot-key ids don't collide with other apps'.
    private let signature: OSType = 0x4D_46_6C_78

    /// Replace all registrations with the given shortcuts. Skips empty/zero-key entries.
    func update(_ shortcuts: [HotKeyAction: GlobalShortcut]) {
        unregisterAll()
        guard !shortcuts.isEmpty else {
            return
        }
        installHandlerIfNeeded()
        for (action, shortcut) in shortcuts where shortcut.keyCode != 0 {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: action.hotKeyID)
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.carbonModifiers,
                id,
                GetEventDispatcherTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
                actionsByID[action.hotKeyID] = action
            }
        }
    }

    func unregisterAll() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        actionsByID.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else {
            return
        }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return noErr
                }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else {
                    return noErr
                }
                let id = hotKeyID.id
                // Carbon delivers hot-key events on the main event target, i.e. the main
                // thread, so it's safe to touch the @MainActor center directly.
                MainActor.assumeIsolated {
                    let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                    if let action = center.actionsByID[id] {
                        center.onAction?(action)
                    }
                }
                return noErr
            },
            1,
            &spec,
            context,
            &eventHandler
        )
    }
}
