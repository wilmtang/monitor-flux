import CoreGraphics
import Foundation

/// Pure math for the popup's iOS-app-icon-style drag reorder, split out from the view so the
/// swap-past-neighbor behavior is unit-testable without a live gesture.
///
/// While a card is dragged, `offset` is its accumulated vertical travel from its current slot.
/// When that travel passes the half-height of an adjacent card, the two swap and `offset` is
/// reduced by that card's span — keeping the dragged card glued to the cursor across the swap
/// (its slot moves by the span, the residual offset shrinks by the same span, so the on-screen
/// position is continuous). Heights are per-card so cards of different sizes (the short built-in
/// card vs a tall external card) swap at the correct threshold.
enum DragReorder {
    static func resolve(
        order: [String],
        draggingKey: String,
        offset: CGFloat,
        heights: [String: CGFloat],
        spacing: CGFloat
    ) -> (order: [String], offset: CGFloat) {
        var order = order
        var offset = offset
        guard var index = order.firstIndex(of: draggingKey) else {
            return (order, offset)
        }

        // Dragging down: swap past each lower neighbor whose midpoint we've crossed.
        while offset > 0, index + 1 < order.count {
            let span = (heights[order[index + 1]] ?? 0) + spacing
            guard span > 0, offset > span / 2 else {
                break
            }
            order.swapAt(index, index + 1)
            offset -= span
            index += 1
        }

        // Dragging up: symmetric, past each upper neighbor.
        while offset < 0, index > 0 {
            let span = (heights[order[index - 1]] ?? 0) + spacing
            guard span > 0, -offset > span / 2 else {
                break
            }
            order.swapAt(index, index - 1)
            offset += span
            index -= 1
        }

        return (order, offset)
    }
}
