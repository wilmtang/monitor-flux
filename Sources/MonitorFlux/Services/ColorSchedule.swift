import Foundation

enum ColorSchedule {
    static func targetTemperature(
        preferences: AppPreferences,
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> Int? {
        switch preferences.colorMode {
        case .off:
            return nil
        case .manual:
            return preferences.manualTemperature.clamped(to: 1000...10000)
        case .clock:
            let minute = calendar.component(.hour, from: date) * 60
                + calendar.component(.minute, from: date)
            return scheduledTemperature(
                preferences: preferences,
                minuteOfDay: minute
            )
        }
    }

    static func scheduledTemperature(
        preferences: AppPreferences,
        minuteOfDay: Int
    ) -> Int {
        let minute = ((minuteOfDay % 1440) + 1440) % 1440
        let transition = preferences.transitionMinutes.clamped(to: 0...240)
        let day = preferences.dayTemperature.clamped(to: 1000...10000)
        let night = preferences.nightTemperature.clamped(to: 1000...10000)

        let sinceWarm = circularMinutes(from: preferences.warmStartMinutes, to: minute)
        let sinceCool = circularMinutes(from: preferences.coolStartMinutes, to: minute)

        if transition > 0, sinceWarm < transition {
            return interpolate(from: day, to: night, progress: Double(sinceWarm) / Double(transition))
        }

        if transition > 0, sinceCool < transition {
            return interpolate(from: night, to: day, progress: Double(sinceCool) / Double(transition))
        }

        return sinceWarm < sinceCool ? night : day
    }

    private static func circularMinutes(from start: Int, to end: Int) -> Int {
        let normalizedStart = ((start % 1440) + 1440) % 1440
        let normalizedEnd = ((end % 1440) + 1440) % 1440
        return (normalizedEnd - normalizedStart + 1440) % 1440
    }

    private static func interpolate(from start: Int, to end: Int, progress: Double) -> Int {
        let clampedProgress = progress.clamped(to: 0...1)
        return Int((Double(start) + (Double(end - start) * clampedProgress)).rounded())
    }
}
