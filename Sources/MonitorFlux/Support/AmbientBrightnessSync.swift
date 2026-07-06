import CoreGraphics
import Foundation

/// Delta-sync external brightness from the built-in panel's observed backlight changes.
/// The built-in remains read-only here; the store executes any external writes.
enum AmbientBrightnessSync {
    struct DisplayContext: Equatable {
        var id: CGDirectDisplayID
        var isBuiltIn: Bool
        var isBrightnessScheduled: Bool
        var canAdjustBrightness: Bool
        var currentBrightness: Double
    }

    struct Adjustment: Equatable {
        var displayID: CGDirectDisplayID
        var targetBrightness: Double
    }

    struct Plan: Equatable {
        var baseline: Double?
        var percentDelta: Int?
        var adjustments: [Adjustment]
    }

    static func plan(
        previousBuiltInBrightness: Double?,
        currentBuiltInBrightness: Double?,
        displays: [DisplayContext]
    ) -> Plan {
        guard let currentBuiltInBrightness else {
            return Plan(baseline: nil, percentDelta: nil, adjustments: [])
        }
        guard let previousBuiltInBrightness else {
            return Plan(baseline: currentBuiltInBrightness, percentDelta: nil, adjustments: [])
        }

        let rawDelta = (currentBuiltInBrightness - previousBuiltInBrightness) * 100
        guard abs(rawDelta) >= 1 else {
            return Plan(baseline: previousBuiltInBrightness, percentDelta: nil, adjustments: [])
        }

        let percentDelta = Int(rawDelta.rounded())
        let fractionDelta = Double(percentDelta) / 100.0
        let adjustments = displays.compactMap { display -> Adjustment? in
            guard !display.isBuiltIn,
                  !display.isBrightnessScheduled,
                  display.canAdjustBrightness
            else {
                return nil
            }
            let target = (display.currentBrightness + fractionDelta).clamped(to: 0...1)
            guard abs(target - display.currentBrightness) >= 0.005 else {
                return nil
            }
            return Adjustment(displayID: display.id, targetBrightness: target)
        }

        return Plan(
            baseline: currentBuiltInBrightness,
            percentDelta: percentDelta,
            adjustments: adjustments
        )
    }
}
