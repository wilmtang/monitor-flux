import Foundation
import SwiftUI

/// A compact day→sunset→night curve for a per-display hardware level (brightness or contrast),
/// the smaller sibling of the warmth `FluxCurveEditor`. It rides the identical global timeline
/// (wake/sunset/bedtime anchors + fade) via `ColorSchedule.scheduledHardwareLevel`, so the shape
/// always matches the warmth schedule's. One handle per phase sets that phase's target; they sit
/// at the same anchors as the warmth handles and drag vertically only, because the times come
/// from the Schedule screen, not per display.
struct HardwareScheduleChart: View {
    @Binding var dayValue: Int
    @Binding var sunsetValue: Int
    @Binding var nightValue: Int
    /// The global schedule shape (anchors + fade), read-only here. Same value the warmth curve
    /// draws from, so the two charts line up in time.
    let preferences: AppPreferences
    /// Brightness vs contrast accent — the chart's only color, so the two read as different controls.
    let accent: Color
    /// Spoken name for the whole chart, e.g. "Brightness schedule curve".
    let accessibilityName: String

    private let range = ControlRanges.hardwarePercent
    /// Vertical breathing room (handle radius + stroke) so a handle at 0%/100% stays fully inside
    /// the chart and grabbable. The curve uses the same inset, so handles stay on it.
    private let verticalInset: CGFloat = 10

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

                handle(.daytime, in: size)
                handle(.sunset, in: size)
                handle(.bedtime, in: size)
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
                sunsetValue: sunsetValue,
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

    private func handle(_ phase: ColorPhase, in size: CGSize) -> some View {
        let x = CGFloat(preferences.startMinutes(for: phase)) / 1440.0 * size.width
        let y = yPosition(for: value(for: phase), height: size.height)

        return Circle()
            .fill(accent.opacity(0.9))
            .frame(width: 16, height: 16)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: accent.opacity(0.28), radius: 6, y: 2)
            .position(x: x, y: y)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        setValue(value(from: drag.location.y, height: size.height), for: phase)
                    }
            )
            .accessibilityLabel("\(phase.label) value handle")
    }

    private func value(for phase: ColorPhase) -> Int {
        switch phase {
        case .daytime:
            dayValue
        case .sunset:
            sunsetValue
        case .bedtime:
            nightValue
        }
    }

    private func setValue(_ newValue: Int, for phase: ColorPhase) {
        switch phase {
        case .daytime:
            dayValue = newValue
        case .sunset:
            sunsetValue = newValue
        case .bedtime:
            nightValue = newValue
        }
    }

    private func yPosition(for value: Int, height: CGFloat) -> CGFloat {
        let clamped = value.clamped(to: range)
        let progress = Double(clamped - range.lowerBound) / Double(range.upperBound - range.lowerBound)
        let usable = max(0, height - 2 * verticalInset)
        return verticalInset + usable * CGFloat(1 - progress)
    }

    private func value(from y: CGFloat, height: CGFloat) -> Int {
        let usable = height - 2 * verticalInset
        guard usable > 0 else {
            return range.lowerBound
        }
        let progress = Double((height - verticalInset - y) / usable).clamped(to: 0...1)
        let raw = range.lowerBound + Int((Double(range.upperBound - range.lowerBound) * progress).rounded())
        return raw.clamped(to: range)
    }
}
