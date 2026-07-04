import Foundation

enum ControlRanges {
    // Matches f.lux's color-temperature range; the upper bound doubles as the
    // neutral reference in `ColorTemperature`, so daytime at 6500 K is untinted.
    static let kelvin = 1200...6500
    static let minuteOfDay = 0...1439
    static let transitionMinutes = 0...240
    // How long before wake the Follow-sunset bedtime begins (f.lux hardcodes 9 h).
    static let bedtimeLeadMinutes = 240...720
    static let hardwarePercent = 0...100
    static let gammaBrightnessPercent = 0...150
    static let gammaContrastPercent = 0...200
    static let ddcDisplayIndex = 1...8
}
