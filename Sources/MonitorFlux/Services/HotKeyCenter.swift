// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import Carbon.HIToolbox
import Foundation

/// An opaque handle to a registered hot key, returned by a registrar so the center can
/// unregister it later. Carbon tokens carry the `EventHotKeyRef`; fakes carry nil.
final class HotKeyToken {
    let carbonRef: EventHotKeyRef?
    init(carbonRef: EventHotKeyRef?) {
        self.carbonRef = carbonRef
    }
}

/// Abstracts global hot-key registration so the center's conflict bookkeeping is testable
/// without Carbon — tests inject a fake that can simulate "this combo is already taken".
@MainActor
protocol HotKeyRegistering: AnyObject {
    /// Invoked with a pressed hot key's action id.
    var onPress: ((UInt32) -> Void)? { get set }
    /// Register a hot key, or return nil if it couldn't be registered (e.g. a conflict).
    func register(keyCode: UInt32, modifiers: UInt32, actionID: UInt32) -> HotKeyToken?
    func unregister(_ token: HotKeyToken)
}

/// Registers the user's custom global shortcuts and routes presses to `onAction`, tracking
/// which ones failed to register (because another app already owns the combo). Carbon hot
/// keys fire system-wide without intercepting every keystroke and need no Accessibility
/// permission. Carbon delivers presses on the main event target, so this is `@MainActor`.
@MainActor
final class HotKeyCenter {
    var onAction: ((HotKeyAction) -> Void)?
    /// Actions whose shortcut couldn't be registered (already taken by another app).
    private(set) var conflictedActions: Set<HotKeyAction> = []

    private let registrar: HotKeyRegistering
    private var tokens: [HotKeyAction: HotKeyToken] = [:]

    init(registrar: HotKeyRegistering = CarbonHotKeyRegistrar()) {
        self.registrar = registrar
        registrar.onPress = { [weak self] actionID in
            guard let self,
                  let action = HotKeyAction.allCases.first(where: { $0.hotKeyID == actionID })
            else {
                return
            }
            self.onAction?(action)
        }
    }

    /// Replace all registrations with `shortcuts`; returns the actions that failed to
    /// register (conflicts), and stores them on `conflictedActions`.
    @discardableResult
    func update(_ shortcuts: [HotKeyAction: GlobalShortcut]) -> Set<HotKeyAction> {
        for token in tokens.values {
            registrar.unregister(token)
        }
        tokens.removeAll()

        var conflicts: Set<HotKeyAction> = []
        // Skip only a genuinely empty shortcut (the legacy-migration `0,0` sentinel). Carbon key
        // code 0 is `kVK_ANSI_A`, so a modified combo on the A key (⌘A) is real and must register —
        // filtering on `keyCode != 0` alone silently dropped it.
        for (action, shortcut) in shortcuts where shortcut.keyCode != 0 || shortcut.carbonModifiers != 0 {
            if let token = registrar.register(
                keyCode: shortcut.keyCode,
                modifiers: shortcut.carbonModifiers,
                actionID: action.hotKeyID
            ) {
                tokens[action] = token
            } else {
                conflicts.insert(action)
            }
        }
        conflictedActions = conflicts
        return conflicts
    }
}

/// Carbon-backed registrar: `RegisterEventHotKey` plus one `kEventHotKeyPressed` handler.
@MainActor
final class CarbonHotKeyRegistrar: HotKeyRegistering {
    var onPress: ((UInt32) -> Void)?
    private var eventHandler: EventHandlerRef?
    // 'MFlx' — a four-char signature so our hot-key ids don't collide with other apps'.
    private let signature: OSType = 0x4D_46_6C_78

    func register(keyCode: UInt32, modifiers: UInt32, actionID: UInt32) -> HotKeyToken? {
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: actionID)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            id,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            return nil
        }
        return HotKeyToken(carbonRef: ref)
    }

    func unregister(_ token: HotKeyToken) {
        if let ref = token.carbonRef {
            UnregisterEventHotKey(ref)
        }
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
                // Carbon delivers hot-key events on the main event target (main thread).
                MainActor.assumeIsolated {
                    let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
                    registrar.onPress?(id)
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
