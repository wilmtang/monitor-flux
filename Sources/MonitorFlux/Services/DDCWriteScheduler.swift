// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import Foundation

/// Per-control throttle for live DDC slider writes, extracted from `AppStore` so the timing
/// behavior is unit-testable. Throttling (rather than a trailing-only debounce) lets the
/// monitor track the slider live instead of only jumping once the user lets go — the
/// behaviour that made MonitorControl feel smoother. Keys are per display *and* control
/// ("<displayID>.b"), so one control's drag never delays another's.
@MainActor
final class DDCWriteScheduler {
    /// How often a held drag is allowed to push a DDC write.
    private let interval: TimeInterval
    /// Trailing (coalesced) writes per control, and the last time each one actually wrote.
    private var workItems: [String: DispatchWorkItem] = [:]
    private var lastWrite: [String: DispatchTime] = [:]

    init(interval: TimeInterval = 0.045) {
        self.interval = interval
    }

    /// Run `apply` now if the control's throttle window has passed (leading edge), else
    /// coalesce it into one trailing write when the window elapses — so a drag still settles
    /// on exactly where the user left it. A newer call supersedes any pending trailing write.
    func schedule(key: String, _ apply: @escaping () -> Void) {
        let now = DispatchTime.now()
        let elapsed = lastWrite[key].map {
            Double(now.uptimeNanoseconds &- $0.uptimeNanoseconds) / 1_000_000_000
        } ?? .infinity

        // A newer value supersedes any still-pending trailing write for this control.
        workItems[key]?.cancel()
        workItems[key] = nil

        guard elapsed < interval else {
            // Leading edge: enough time has passed, write now so the monitor tracks.
            lastWrite[key] = now
            apply()
            return
        }

        // Trailing edge: coalesce until the throttle window elapses, then write the
        // latest value so the drag still settles on exactly where the user left it.
        let delay = interval - elapsed
        let item = DispatchWorkItem { [weak self] in
            self?.workItems[key] = nil
            self?.lastWrite[key] = DispatchTime.now()
            apply()
        }
        workItems[key] = item
        DispatchQueue.main.asyncAfter(deadline: now + delay, execute: item)
    }

    /// Drop throttle bookkeeping — and cancel pending trailing writes — for keys that are no
    /// longer live (their display disconnected). The entries are tiny but unbounded over a
    /// long uptime, and a cancelled write can't land on a re-used display ID.
    func retainOnly(where isLive: (String) -> Bool) {
        lastWrite = lastWrite.filter { isLive($0.key) }
        for key in workItems.keys where !isLive(key) {
            workItems[key]?.cancel()
            workItems[key] = nil
        }
    }
}
