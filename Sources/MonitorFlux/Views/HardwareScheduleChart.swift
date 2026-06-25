import Foundation
import SwiftUI

/// A compact day→night curve for a per-display hardware level (brightness or contrast), the
/// smaller sibling of the warmth `FluxCurveEditor`. It rides the identical global timeline
/// (wake/sunset/bedtime anchors + fade) via `ColorSchedule.scheduledHardwareLevel`, so the
/// shape always matches the warmth schedule's. Two handles set the daytime and night targets;
/// they drag vertically only, because the times come from the Schedule screen, not per display.
struct HardwareScheduleChart: View {
    @Binding var dayValue: Int
    @Binding var nightValue: Int
    /// The global schedule shape (anchors + fade), read-only here. Same value the warmth curve
    /// draws from, so the two charts line up in time.
    let preferences: AppPreferences
    /// Brightness vs contrast accent — the chart's only color, so the two read as different controls.
    let accent: Color
    /// Spoken name for the whole chart, e.g. "Brightness schedule curve".
    let accessibilityName: String

    private let range = ControlRanges.hardwarePercent

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Canvas { context, canvasSize in
                    drawGrid(in: &context, size: canvasSize)
                    drawFill(in: &context, size: canvasSize)
                    drawCurve(in: &context, size: canvasSize)
                }

                nowMarker(in: size)

                handle(isDay: true, in: size)
                handle(isDay: false, in: size)
            }
            .contentShape(Rectangle())
        }
        .frame(height: 96)
        .accessibilityLabel(accessibilityName)
    }

    /// A thin, non-draggable line at the current minute — a quieter version of the warmth curve's
    /// marker (no scrub preview here). Driven by `TimelineView(.everyMinute)`, the laziest cadence
    /// that keeps it positioned to the schedule's one-minute resolution.
    private func nowMarker(in size: CGSize) -> some View {
        TimelineView(.everyMinute) { context in
            let minute = Self.minuteOfDay(from: context.date)
            let x = CGFloat(minute) / 1440.0 * size.width
            Capsule()
                .fill(.white.opacity(0.65))
                .frame(width: 1.5, height: size.height)
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
        for hour in stride(from: 0, through: 24, by: 4) {
            let x = CGFloat(hour) / 24.0 * size.width
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        let y = size.height * 0.5
        grid.move(to: CGPoint(x: 0, y: y))
        grid.addLine(to: CGPoint(x: size.width, y: y))
        context.stroke(grid, with: .color(.white.opacity(0.42)), lineWidth: 1)
    }

    private func drawFill(in context: inout GraphicsContext, size: CGSize) {
        var area = valuePath(size: size)
        area.addLine(to: CGPoint(x: size.width, y: size.height))
        area.addLine(to: CGPoint(x: 0, y: size.height))
        area.closeSubpath()

        let gradient = Gradient(colors: [accent.opacity(0.32), accent.opacity(0.10)])
        context.fill(area, with: .linearGradient(
            gradient,
            startPoint: CGPoint(x: 0, y: 0),
            endPoint: CGPoint(x: 0, y: size.height)
        ))
    }

    private func drawCurve(in context: inout GraphicsContext, size: CGSize) {
        let curve = valuePath(size: size)
        context.stroke(curve, with: .color(accent.opacity(0.9)), lineWidth: 2.5)
    }

    private func valuePath(size: CGSize) -> Path {
        var path = Path()
        for step in 0...144 {
            let minute = step * 10
            let value = ColorSchedule.scheduledHardwareLevel(
                dayValue: dayValue,
                nightValue: nightValue,
                preferences: preferences,
                minuteOfDay: minute
            )
            let point = CGPoint(
                x: CGFloat(minute) / 1440.0 * size.width,
                y: yPosition(for: value, height: size.height)
            )

            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    private func handle(isDay: Bool, in size: CGSize) -> some View {
        let current = isDay ? dayValue : nightValue
        let x = CGFloat(plateauMinute(isDay: isDay)) / 1440.0 * size.width
        let y = yPosition(for: current, height: size.height)

        return Circle()
            .fill(accent.opacity(0.9))
            .frame(width: 16, height: 16)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: accent.opacity(0.28), radius: 6, y: 2)
            .position(x: x, y: y)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let newValue = value(from: drag.location.y, height: size.height)
                        if isDay {
                            dayValue = newValue
                        } else {
                            nightValue = newValue
                        }
                    }
            )
            .accessibilityLabel(isDay ? "Daytime value handle" : "Night value handle")
    }

    /// Place each handle at the middle of its plateau so it sits on the flat part of the curve,
    /// clear of the fades right after each anchor. The handle's height comes from the bound value,
    /// so dragging edits the plateau directly.
    private func plateauMinute(isDay: Bool) -> Int {
        let start = isDay ? preferences.coolStartMinutes : preferences.sunsetStartMinutes
        let end = isDay ? preferences.sunsetStartMinutes : preferences.coolStartMinutes
        let span = circularSpan(from: start, to: end)
        return (start + span / 2) % 1440
    }

    private func circularSpan(from start: Int, to end: Int) -> Int {
        let normalizedStart = ((start % 1440) + 1440) % 1440
        let normalizedEnd = ((end % 1440) + 1440) % 1440
        return (normalizedEnd - normalizedStart + 1440) % 1440
    }

    private func yPosition(for value: Int, height: CGFloat) -> CGFloat {
        let clamped = value.clamped(to: range)
        let progress = Double(clamped - range.lowerBound) / Double(range.upperBound - range.lowerBound)
        return height - (height * CGFloat(progress))
    }

    private func value(from y: CGFloat, height: CGFloat) -> Int {
        guard height > 0 else {
            return range.lowerBound
        }
        let progress = Double((height - y) / height).clamped(to: 0...1)
        let raw = range.lowerBound + Int((Double(range.upperBound - range.lowerBound) * progress).rounded())
        return raw.clamped(to: range)
    }
}
