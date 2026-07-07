import CoreGraphics

/// Manual linked-control fanout. The store applies the source display through the normal
/// slider/key path first; this planner only returns the peer displays that should receive
/// the same absolute target.
enum DisplayControlSync {
    struct BrightnessContext: Equatable {
        var id: CGDirectDisplayID
        var canAdjustBrightness: Bool
    }

    struct ContrastContext: Equatable {
        var id: CGDirectDisplayID
        var canAdjustContrast: Bool
    }

    struct BrightnessAdjustment: Equatable {
        var displayID: CGDirectDisplayID
        var targetBrightness: Double
    }

    struct ContrastAdjustment: Equatable {
        var displayID: CGDirectDisplayID
        var targetContrast: Int
    }

    static func brightnessAdjustments(
        sourceID: CGDirectDisplayID,
        targetBrightness: Double,
        enabled: Bool,
        displays: [BrightnessContext]
    ) -> [BrightnessAdjustment] {
        guard enabled else {
            return []
        }
        let target = targetBrightness.clamped(to: 0...1)
        return displays.compactMap { display in
            guard display.id != sourceID,
                  display.canAdjustBrightness
            else {
                return nil
            }
            return BrightnessAdjustment(displayID: display.id, targetBrightness: target)
        }
    }

    static func contrastAdjustments(
        sourceID: CGDirectDisplayID,
        targetContrast: Int,
        enabled: Bool,
        displays: [ContrastContext]
    ) -> [ContrastAdjustment] {
        guard enabled else {
            return []
        }
        let target = targetContrast.clamped(to: ControlRanges.hardwarePercent)
        return displays.compactMap { display in
            guard display.id != sourceID,
                  display.canAdjustContrast
            else {
                return nil
            }
            return ContrastAdjustment(displayID: display.id, targetContrast: target)
        }
    }
}
