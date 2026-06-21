import CoreGraphics
import Foundation

enum GammaPlan {
    static func adjustments(
        displays: [DisplayInfo],
        preferences: AppPreferences
    ) -> [CGDirectDisplayID: GammaAdjustment] {
        guard preferences.gammaEnabled else {
            return [:]
        }

        let targetTemperature = ColorSchedule.targetTemperature(preferences: preferences)
        return Dictionary(uniqueKeysWithValues: displays.compactMap { display in
            let displayPreferences = preferences.displayPreferences[display.key, default: DisplayPreferences()]
                .normalized()
            let adjustment = GammaAdjustment(
                temperature: displayPreferences.colorEnabled ? targetTemperature : nil,
                brightnessPercent: displayPreferences.gammaControlsEnabled
                    ? displayPreferences.gammaBrightness
                    : 100,
                contrastPercent: displayPreferences.gammaControlsEnabled
                    ? displayPreferences.gammaContrast
                    : 100
            )
            return adjustment.isNeutral ? nil : (display.id, adjustment)
        })
    }
}
