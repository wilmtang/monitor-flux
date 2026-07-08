// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import Foundation

/// Pure ordering logic for the popup's drag-to-reorder display cards, split out from the store
/// so it can be unit-tested without a live `AppStore`/`NSWorkspace`.
enum DisplayOrdering {
    /// `keys` arranged by their position in `order`. Keys absent from `order` — freshly connected
    /// displays — keep their original relative position, after all listed keys. Stable.
    static func sorted(_ keys: [String], by order: [String]) -> [String] {
        let rank = Dictionary(
            order.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        return keys.enumerated().sorted { lhs, rhs in
            switch (rank[lhs.element], rank[rhs.element]) {
            case let (left?, right?): return left < right
            case (nil, .some): return false             // ranked sorts before unranked
            case (.some, nil): return true
            case (nil, nil): return lhs.offset < rhs.offset  // keep detection order, stably
            }
        }
        .map(\.element)
    }

    /// `keys` with `dragged` moved to just before `target`. A no-op when either key is missing or
    /// the two are equal.
    static func reordered(_ keys: [String], moving dragged: String, before target: String) -> [String] {
        guard dragged != target, keys.contains(dragged), keys.contains(target) else {
            return keys
        }
        var result = keys
        result.removeAll { $0 == dragged }
        guard let to = result.firstIndex(of: target) else {
            return keys
        }
        result.insert(dragged, at: to)
        return result
    }
}
