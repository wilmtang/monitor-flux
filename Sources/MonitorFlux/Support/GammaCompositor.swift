import Foundation

struct GammaAdjustment: Equatable, Sendable {
    var temperature: Int?
    var brightnessPercent: Int
    var contrastPercent: Int

    static let neutral = GammaAdjustment(
        temperature: nil,
        brightnessPercent: 100,
        contrastPercent: 100
    )

    var isNeutral: Bool {
        temperature == nil
            && brightnessPercent == 100
            && contrastPercent == 100
    }
}

enum GammaCompositor {
    static func adjustedValue(
        _ value: Double,
        channelMultiplier: Double,
        brightnessPercent: Int,
        contrastPercent: Int
    ) -> Double {
        let brightness = Double(brightnessPercent.clamped(to: 0...150)) / 100.0
        let contrast = Double(contrastPercent.clamped(to: 0...200)) / 100.0
        let warmed = value * channelMultiplier
        let contrasted = ((warmed - 0.5) * contrast) + 0.5
        return (contrasted * brightness).clamped(to: 0...1)
    }

    static func multipliers(for adjustment: GammaAdjustment) -> (red: Double, green: Double, blue: Double) {
        guard let temperature = adjustment.temperature else {
            return (1, 1, 1)
        }

        return ColorTemperature.multipliers(for: temperature)
    }
}
