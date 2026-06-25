import Foundation
import SwiftUI

enum FluxCurveHandle: Hashable {
    case day
    case sunset
    case night
}

struct FluxCurveEditor: View {
    @Binding var dayTemperature: Int
    @Binding var sunsetTemperature: Int
    @Binding var nightTemperature: Int
    @Binding var warmStartMinutes: Int
    @Binding var coolStartMinutes: Int
    @Binding var sunsetStartMinutes: Int
    let transitionMinutes: Int

    private let minKelvin = ControlRanges.kelvin.lowerBound
    private let maxKelvin = ControlRanges.kelvin.upperBound

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Canvas { context, canvasSize in
                    drawGrid(in: &context, size: canvasSize)
                    drawTemperatureFill(in: &context, size: canvasSize)
                    drawTemperatureCurve(in: &context, size: canvasSize)
                }

                currentTimeLine(in: size)

                handle(.day, in: size)
                handle(.sunset, in: size)
                handle(.night, in: size)
            }
            .contentShape(Rectangle())
        }
        .frame(height: 150)
        .accessibilityLabel("Color schedule curve")
    }

    /// A vertical "now" marker at the current time of day, so the curve reads against the real
    /// clock. Sits above the curve but below the handles (and ignores hits) so it never gets in the
    /// way of dragging. Driven by `TimelineView(.everyMinute)`: it redraws at most once a minute,
    /// and only while on screen — the laziest cadence that still keeps the position correct, since
    /// the schedule's own resolution is one minute (the line shifts ~1px per minute).
    private func currentTimeLine(in size: CGSize) -> some View {
        TimelineView(.everyMinute) { context in
            let minute = Self.minuteOfDay(from: context.date)
            let x = CGFloat(minute) / 1440.0 * size.width
            ZStack {
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: 2, height: size.height)
                    .shadow(color: .white.opacity(0.4), radius: 3)
                Circle()
                    .fill(.white)
                    .frame(width: 7, height: 7)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                    .offset(y: -size.height / 2)
            }
            .position(x: x, y: size.height / 2)
            .allowsHitTesting(false)
        }
    }

    private static func minuteOfDay(from date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        var grid = Path()
        for hour in stride(from: 0, through: 24, by: 2) {
            let x = CGFloat(hour) / 24.0 * size.width
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        for fraction in stride(from: 0.25, through: 0.75, by: 0.25) {
            let y = size.height * CGFloat(fraction)
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(.white.opacity(0.42)), lineWidth: 1)
    }

    private func drawTemperatureFill(in context: inout GraphicsContext, size: CGSize) {
        var area = temperaturePath(size: size)
        area.addLine(to: CGPoint(x: size.width, y: size.height))
        area.addLine(to: CGPoint(x: 0, y: size.height))
        area.closeSubpath()

        let gradient = Gradient(colors: [
            .blue.opacity(0.18),
            .phaseSunset.opacity(0.30),
            .phaseSunset.opacity(0.14)
        ])
        context.fill(area, with: .linearGradient(
            gradient,
            startPoint: CGPoint(x: 0, y: size.height),
            endPoint: CGPoint(x: size.width, y: 0)
        ))
    }

    private func drawTemperatureCurve(in context: inout GraphicsContext, size: CGSize) {
        let curve = temperaturePath(size: size)
        context.stroke(curve, with: .color(.phaseSunset.opacity(0.85)), lineWidth: 2.5)

        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: size.height - 3))
        baseline.addLine(to: CGPoint(x: size.width, y: size.height - 3))
        context.stroke(baseline, with: .color(.blue.opacity(0.55)), lineWidth: 3)
    }

    private func temperaturePath(size: CGSize) -> Path {
        var path = Path()
        let preferences = previewPreferences()

        for step in 0...144 {
            let minute = step * 10
            let temperature = ColorSchedule.scheduledTemperature(
                preferences: preferences,
                minuteOfDay: minute
            )
            let point = CGPoint(
                x: CGFloat(minute) / 1440.0 * size.width,
                y: yPosition(for: temperature, height: size.height)
            )

            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        return path
    }

    private func handle(_ handle: FluxCurveHandle, in size: CGSize) -> some View {
        let point = point(for: handle, in: size)
        let color = color(for: handle)

        return Circle()
            .fill(color.opacity(0.9))
            .frame(width: 20, height: 20)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: color.opacity(0.28), radius: 8, y: 3)
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        update(handle, location: value.location, size: size)
                    }
            )
            .accessibilityLabel("\(phaseLabel(for: handle)) color handle")
    }

    private func color(for handle: FluxCurveHandle) -> Color {
        switch handle {
        case .day:
            .phaseDaytime
        case .sunset:
            .phaseSunset
        case .night:
            .phaseBedtime
        }
    }

    private func phaseLabel(for handle: FluxCurveHandle) -> String {
        switch handle {
        case .day:
            "Daytime"
        case .sunset:
            "Sunset"
        case .night:
            "Bedtime"
        }
    }

    private func point(for handle: FluxCurveHandle, in size: CGSize) -> CGPoint {
        switch handle {
        case .day:
            CGPoint(
                x: CGFloat(coolStartMinutes) / 1440.0 * size.width,
                y: yPosition(for: dayTemperature, height: size.height)
            )
        case .sunset:
            CGPoint(
                x: CGFloat(sunsetStartMinutes) / 1440.0 * size.width,
                y: yPosition(for: sunsetTemperature, height: size.height)
            )
        case .night:
            CGPoint(
                x: CGFloat(warmStartMinutes) / 1440.0 * size.width,
                y: yPosition(for: nightTemperature, height: size.height)
            )
        }
    }

    private func update(_ handle: FluxCurveHandle, location: CGPoint, size: CGSize) {
        let minute = roundedMinutes(from: location.x, width: size.width)
        let kelvin = roundedKelvin(from: location.y, height: size.height)

        switch handle {
        case .day:
            coolStartMinutes = minute
            dayTemperature = kelvin
        case .sunset:
            sunsetStartMinutes = minute
            sunsetTemperature = kelvin
        case .night:
            warmStartMinutes = minute
            nightTemperature = kelvin
        }
    }

    private func previewPreferences() -> AppPreferences {
        var preferences = AppPreferences.defaults
        preferences.colorMode = .clock
        preferences.dayTemperature = dayTemperature
        preferences.sunsetTemperature = sunsetTemperature
        preferences.nightTemperature = nightTemperature
        preferences.warmStartMinutes = warmStartMinutes
        preferences.coolStartMinutes = coolStartMinutes
        preferences.sunsetStartMinutes = sunsetStartMinutes
        preferences.transitionMinutes = transitionMinutes
        return preferences
    }

    private func yPosition(for kelvin: Int, height: CGFloat) -> CGFloat {
        let clamped = kelvin.clamped(to: minKelvin...maxKelvin)
        let progress = Double(clamped - minKelvin) / Double(maxKelvin - minKelvin)
        return height - (height * CGFloat(progress))
    }

    private func roundedMinutes(from x: CGFloat, width: CGFloat) -> Int {
        guard width > 0 else {
            return 0
        }

        let raw = Int((x / width * 1440).rounded())
        let rounded = Int((Double(raw) / 15.0).rounded()) * 15
        return rounded.clamped(to: ControlRanges.minuteOfDay)
    }

    private func roundedKelvin(from y: CGFloat, height: CGFloat) -> Int {
        guard height > 0 else {
            return dayTemperature
        }

        let progress = Double((height - y) / height).clamped(to: 0...1)
        let raw = minKelvin + Int((Double(maxKelvin - minKelvin) * progress).rounded())
        return (Int((Double(raw) / 100.0).rounded()) * 100).clamped(to: ControlRanges.kelvin)
    }
}
