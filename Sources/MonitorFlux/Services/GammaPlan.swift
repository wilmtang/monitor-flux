import CoreGraphics
import Foundation

enum GammaPlan {
    /// Gamma adjustments keyed by the **effective** display ID (the mirror master when mirroring),
    /// so a mirror set is warmed once through its master rather than written per child. AirPlay /
    /// virtual displays are excluded — gamma has no effect there, so their software dimming runs
    /// through `ShadeController` instead.
    static func adjustments(
        displays: [DisplayInfo],
        preferences: AppPreferences
    ) -> [CGDirectDisplayID: GammaAdjustment] {
        // Warmth (temperature) rides the master switch; software *dimming* does not — it's
        // plain dimming, not a color change, so the unified Brightness control keeps working
        // with Warmth off.
        let targetTemperature = preferences.gammaEnabled
            ? ColorSchedule.targetTemperature(preferences: preferences)
            : nil
        var result: [CGDirectDisplayID: GammaAdjustment] = [:]
        for display in displays {
            // AirPlay / virtual displays ignore gamma writes — leave them to the shade overlay.
            guard !display.isVirtual else {
                continue
            }
            let displayPreferences = preferences.displayPreferences[display.key, default: DisplayPreferences()]
                .normalized()
            let adjustment = GammaAdjustment(
                temperature: displayPreferences.colorEnabled ? targetTemperature : nil,
                // The software-brightness value always applies; `DimmingMode` only routes the
                // unified control (`.hardware` clears the value when selected, rather than
                // gating it here — no hidden interactions).
                brightnessPercent: displayPreferences.gammaBrightness,
                // Software (gamma) contrast was removed: it only ever produced a banding-prone
                // approximation, and the built-in panel — its only would-be user — has no real
                // contrast control. Contrast is now a DDC (external monitor) hardware control only.
                contrastPercent: 100
            )
            guard !adjustment.isNeutral else {
                continue
            }
            // Mirror set: write through the master. Prefer the master's own adjustment so a
            // mirrored child can't overwrite it; a child only fills an otherwise-empty slot.
            let target = display.effectiveID
            if result[target] == nil || display.id == target {
                result[target] = adjustment
            }
        }
        return result
    }
}
