// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import Foundation
import SwiftUI

/// A compact day→sunset→night curve for a per-display hardware level (brightness or contrast),
/// the smaller sibling of the warmth `FluxCurveEditor`. It rides the identical resolved timeline
/// (events + fade) via `ColorSchedule.scheduledHardwareLevel`, so the shape always matches the
/// warmth schedule's — including Follow-sunset days. One handle per phase sets that phase's
/// target; they sit at the same anchors as the warmth handles and drag vertically only, because
/// the times come from the Schedule screen, not per display.
struct HardwareScheduleChart: View {
    @Binding var dayValue: Int
    @Binding var sunsetValue: Int
    @Binding var nightValue: Int
    /// The resolved global schedule (events + fade), read-only here. Same value the warmth
    /// curve draws from, so the two charts line up in time.
    let schedule: ResolvedSchedule
    /// Brightness vs contrast accent — the chart's only color, so the two read as different controls.
    let accent: Color
    /// Spoken name for the whole chart, e.g. "Brightness schedule curve".
    let accessibilityName: String
    /// The minute being scrub-previewed (drives the prominent marker), or `nil` for "showing now".
    /// Shared with the warmth curve via `AppStore.schedulePreviewMinute`, so every chart's marker
    /// moves together while scrubbing.
    var previewMinute: Int? = nil
    /// Called with the dragged minute-of-day as the user scrubs the time marker, so the screen
    /// previews how it will look then. `{ _ in }` leaves the marker static (no preview wired).
    var onPreview: (Int) -> Void = { _ in }

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

                timeMarkers(in: size)

                handle(.daytime, in: size)
                handle(.sunset, in: size)
                handle(.bedtime, in: size)
            }
            .contentShape(Rectangle())
        }
        .frame(height: 96)
        .accessibilityLabel(accessibilityName)
    }

    /// The live "now" line, and — while a preview is scrubbed — a faint reference at the real
    /// current time plus a prominent, draggable marker at the previewed minute. Identical
    /// treatment to the warmth curve's `timeMarkers`, so dragging either scrubs the same shared
    /// preview and the hardware charts read as one family with the main scheduler. Driven by
    /// `TimelineView(.everyMinute)`, the laziest cadence that keeps the position at the schedule's
    /// one-minute resolution.
    private func timeMarkers(in size: CGSize) -> some View {
        TimelineView(.everyMinute) { context in
            let nowMinute = Self.minuteOfDay(from: context.date)
            ZStack {
                // A faint marker at the real "now" while the preview is held elsewhere, so the
                // user keeps a sense of the actual clock.
                if previewMinute != nil {
                    marker(at: nowMinute, in: size, prominent: false, draggable: false)
                }
                // The active marker — the live now, or the scrubbed preview. Always draggable;
                // dragging previews the screen's brightness/contrast (and warmth) at that time.
                marker(at: previewMinute ?? nowMinute, in: size, prominent: true, draggable: true)
            }
        }
    }

    @ViewBuilder
    private func marker(at minute: Int, in size: CGSize, prominent: Bool, draggable: Bool) -> some View {
        let x = CGFloat(minute) / 1440.0 * size.width
        let visual = ZStack {
            Capsule()
                .fill(.white.opacity(prominent ? 0.9 : 0.3))
                .frame(width: prominent ? 2 : 1.5, height: size.height)
                .shadow(color: .white.opacity(prominent ? 0.4 : 0), radius: 3)
            Circle()
                .fill(.white.opacity(prominent ? 1 : 0.45))
                .frame(width: 7, height: 7)
                .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                .offset(y: -size.height / 2)
        }

        if draggable {
            // A wide invisible grab strip around the thin line so it's easy to catch. `.position`
            // reports the drag in the chart's space (not the moving strip's), so the marker tracks
            // the cursor without feeding back on itself.
            visual
                .frame(width: 26, height: size.height)
                .contentShape(Rectangle())
                .position(x: x, y: size.height / 2)
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            guard size.width > 0 else { return }
                            let dragged = Int((value.location.x / size.width * 1440).rounded())
                                .clamped(to: ControlRanges.minuteOfDay)
                            onPreview(dragged)
                        }
                )
        } else {
            visual
                .frame(width: 7, height: size.height)
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
                schedule: schedule,
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
        let x = CGFloat(anchorMinute(for: phase)) / 1440.0 * size.width
        let y = yPosition(for: value(for: phase), height: size.height)

        // Two hues at once: the control's accent forms the ring (so brightness and contrast handles
        // stay distinct from each other), and a phase-colored core — the same Wake/Sunset/Bedtime
        // hues as the warmth curve's dots — marks which phase this handle sets. A white hairline
        // keeps the core legible where the two colors are close (gold ring / yellow daytime core).
        return ZStack {
            Circle()
                .fill(accent.opacity(0.95))
            Circle()
                .fill(Self.phaseColor(phase))
                .frame(width: 8, height: 8)
            Circle()
                .strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: 8, height: 8)
        }
            .frame(width: 16, height: 16)
            .shadow(color: accent.opacity(0.28), radius: 6, y: 2)
            .position(x: x, y: y)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        setValue(value(from: drag.location.y, height: size.height), for: phase)
                    }
            )
            .accessibilityLabel("\(phase.label) value handle")
            .accessibilityValue("\(value(for: phase))%")
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 5 : -5
                setValue((value(for: phase) + delta).clamped(to: range), for: phase)
            }
    }

    /// The Wake/Sunset/Bedtime hue for a phase's handle core — the same palette the warmth curve's
    /// dots use, so a phase looks the same on every chart.
    private static func phaseColor(_ phase: ColorPhase) -> Color {
        switch phase {
        case .daytime:
            .phaseDaytime
        case .sunset:
            .phaseSunset
        case .bedtime:
            .phaseBedtime
        }
    }

    /// Where a phase's handle sits — the same effective anchors as the warmth chart.
    private func anchorMinute(for phase: ColorPhase) -> Int {
        switch phase {
        case .daytime:
            schedule.dayStartMinutes
        case .sunset:
            schedule.sunsetMinutes
        case .bedtime:
            schedule.bedtimeStartMinutes
        }
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
