import Foundation

enum ColorTemperature {
    static func multipliers(for kelvin: Int) -> (red: Double, green: Double, blue: Double) {
        let target = rgb(for: kelvin.clamped(to: 1000...10000))
        let neutral = rgb(for: 6500)

        return (
            red: (target.red / neutral.red).clamped(to: 0...1),
            green: (target.green / neutral.green).clamped(to: 0...1),
            blue: (target.blue / neutral.blue).clamped(to: 0...1)
        )
    }

    private static func rgb(for kelvin: Int) -> (red: Double, green: Double, blue: Double) {
        let temperature = Double(kelvin) / 100.0
        let red: Double
        let green: Double
        let blue: Double

        if temperature <= 66 {
            red = 255
            green = 99.4708025861 * log(temperature) - 161.1195681661
            if temperature <= 19 {
                blue = 0
            } else {
                blue = 138.5177312231 * log(temperature - 10) - 305.0447927307
            }
        } else {
            red = 329.698727446 * pow(temperature - 60, -0.1332047592)
            green = 288.1221695283 * pow(temperature - 60, -0.0755148492)
            blue = 255
        }

        return (
            red: red.clamped(to: 0...255),
            green: green.clamped(to: 0...255),
            blue: blue.clamped(to: 0...255)
        )
    }
}
