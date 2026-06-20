import Foundation

enum MinuteFormatting {
    static func label(for minutes: Int) -> String {
        let normalized = ((minutes % 1440) + 1440) % 1440
        let hour = normalized / 60
        let minute = normalized % 60
        var components = DateComponents()
        components.calendar = Calendar.current
        components.hour = hour
        components.minute = minute

        guard let date = components.calendar?.date(from: components) else {
            return String(format: "%02d:%02d", hour, minute)
        }

        return date.formatted(date: .omitted, time: .shortened)
    }
}
