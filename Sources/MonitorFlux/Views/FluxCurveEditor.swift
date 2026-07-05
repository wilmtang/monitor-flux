import Foundation
import SwiftUI

enum FluxCurveHandle: Hashable {
    case day
    case sunset
    case night

    var phase: ColorPhase {
        switch self {
        case .day:
            .daytime
        case .sunset:
            .sunset
        case .night:
            .bedtime
        }
    }
}

struct FluxCurveEditor: View {
    @Binding var dayTemperature: Int
    @Binding var sunsetTemperature: Int
    @Binding var nightTemperature: Int
    /// The resolved day driving the curve shape and the handles' horizontal positions —
    /// the same value the live engine applies, so the chart always shows the truth
    /// (including Follow-sunset's pre-dawn bridge and squeezed-sunset days).
    let schedule: ResolvedSchedule
    /// Follow-sunset: the times come from the sun and the wake time, so horizontal drags are
    /// ignored — handles adjust warmth only. Set-times leaves both axes live.
    var timesLocked = false
    /// A thin marker at the wake time, shown when wake isn't where any handle sits (sunrise
    /// mornings put the daytime handle on the sunrise, not the wake).
    var wakeTickMinute: Int? = nil
    /// The minute being scrub-previewed (drives the prominent marker), or `nil` for "showing now".
    var previewMinute: Int? = nil
    /// Called with the dragged minute-of-day as the user scrubs the time marker. Dragging works in
    /// any mode — the store switches to the clock schedule when it fires.
    var onPreview: (Int) -> Void = { _ in }
    /// Called with a handle's phase and its dragged minute-of-day (already clamped into cyclic
    /// order) while times are unlocked. The owner commits it to the store.
    var onTimeEdit: (ColorPhase, Int) -> Void = { _, _ in }

    /// Resolves the phase fill colors (some are appearance-adaptive) to concrete sRGB here in the
    /// view — where the appearance is known — so the fill can blend them numerically inside `Canvas`.
    @Environment(\.self) private var environment

    private let minKelvin = ControlRanges.kelvin.lowerBound
    private let maxKelvin = ControlRanges.kelvin.upperBound
    /// Vertical breathing room (handle radius + stroke) so a handle parked at the warmest/coolest
    /// extreme stays fully inside the chart instead of half-clipped — and therefore fully grabbable.
    /// The curve uses the same inset, so handles still sit exactly on it.
    private let verticalInset: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Canvas { context, canvasSize in
                    drawGrid(in: &context, size: canvasSize)
                    drawTemperatureFill(in: &context, size: canvasSize)
                    drawTemperatureCurve(in: &context, size: canvasSize)
                }

                if let wakeTickMinute {
                    wakeTick(at: wakeTickMinute, in: size)
                }

                timeMarkers(in: size)

                handle(.day, in: size)
                handle(.sunset, in: size)
                handle(.night, in: size)
            }
            .contentShape(Rectangle())
        }
        .frame(height: 150)
        .accessibilityLabel("Color schedule curve")
    }

    /// The time markers on the curve: the live "now" line, and — while a preview is being
    /// scrubbed — a faint reference at the real current time plus a prominent, draggable marker at
    /// the previewed time. Driven by `TimelineView(.everyMinute)`, so it redraws at most once a
    /// minute (and only while on screen) — the laziest cadence that keeps the position correct,
    /// since the schedule's resolution is one minute. Sits above the curve, below the handles.
    private func timeMarkers(in size: CGSize) -> some View {
        TimelineView(.everyMinute) { context in
            let nowMinute = Self.minuteOfDay(from: context.date)
            let activeMinute = previewMinute ?? nowMinute
            ZStack {
                // A faint marker at the real "now" while the preview is held at another time, so
                // the user keeps a sense of the actual clock.
                if previewMinute != nil {
                    marker(at: nowMinute, in: size, prominent: false, draggable: false)
                }
                // The active marker — the live now, or the scrubbed preview. Always draggable;
                // dragging previews the screen's warmth at that time (and adopts clock mode).
                marker(at: activeMinute, in: size, prominent: true, draggable: true)
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
            // reports the drag location in the editor's space (not the moving strip's), so the
            // marker tracks the cursor without feeding back on itself.
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

    /// The wake marker for locked-times days: quieter than the now line, tinted like the Wake
    /// stepper so the two read as the same value.
    private func wakeTick(at minute: Int, in size: CGSize) -> some View {
        let x = CGFloat(((minute % 1440) + 1440) % 1440) / 1440.0 * size.width
        return Capsule()
            .fill(Color.phaseDaytime.opacity(0.7))
            .frame(width: 1.5, height: size.height)
            .position(x: x, y: size.height / 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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

    /// Shade the area under the curve with each phase's own color — wake→sunset as daytime gold,
    /// sunset→bedtime as sunset orange, the night wings as bedtime indigo — but blended *through*
    /// the fade windows instead of hard-cut at each boundary, so the shading eases from one phase's
    /// color to the next exactly as the curve's warmth does. The horizontal hue runs as a gradient
    /// across the whole area (blended per 10-min sample via `scheduledPhaseMix`), and a top-down
    /// alpha mask gives the band its area-chart falloff (stronger at the curve, fainter at the floor).
    private func drawTemperatureFill(in context: inout GraphicsContext, size: CGSize) {
        var area = temperaturePath(size: size)
        area.addLine(to: CGPoint(x: size.width, y: size.height))
        area.addLine(to: CGPoint(x: 0, y: size.height))
        area.closeSubpath()

        let stops = (0...144).map { step -> Gradient.Stop in
            let minute = step * fillStep
            let mix = ColorSchedule.scheduledPhaseMix(schedule: schedule, minuteOfDay: minute)
            return Gradient.Stop(
                color: blendedFillColor(from: mix.from, to: mix.to, progress: mix.progress),
                location: Double(minute) / 1440.0
            )
        }
        let hue = Gradient(stops: stops)

        // Confine everything to a layer so the two clips don't leak onto the curve/handles drawn next.
        context.drawLayer { layer in
            layer.clip(to: area)
            // The vertical falloff, applied as an alpha mask so it composes with the horizontal hue.
            layer.clipToLayer { mask in
                mask.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(
                        Gradient(colors: [.white.opacity(0.34), .white.opacity(0.10)]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )
            }
            layer.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    hue,
                    startPoint: CGPoint(x: 0, y: size.height / 2),
                    endPoint: CGPoint(x: size.width, y: size.height / 2)
                )
            )
        }
    }

    private func fillColor(for phase: ColorPhase) -> Color {
        switch phase {
        case .daytime:
            .phaseDaytime
        case .sunset:
            .phaseSunset
        case .bedtime:
            .phaseBedtime
        }
    }

    /// The two phases' fill colors mixed by `progress`, resolved to concrete sRGB against the
    /// current appearance so it's stable inside `Canvas`. `progress == 1` (or from == to) is the
    /// settled phase color; a value in between is a point in that phase's fade.
    private func blendedFillColor(from: ColorPhase, to: ColorPhase, progress: Double) -> Color {
        let a = fillColor(for: from).resolve(in: environment)
        let b = fillColor(for: to).resolve(in: environment)
        let t = Float(progress.clamped(to: 0...1))
        return Color(
            .sRGB,
            red: Double(a.red + (b.red - a.red) * t),
            green: Double(a.green + (b.green - a.green) * t),
            blue: Double(a.blue + (b.blue - a.blue) * t)
        )
    }

    private func drawTemperatureCurve(in context: inout GraphicsContext, size: CGSize) {
        let curve = temperaturePath(size: size)
        context.stroke(curve, with: .color(.phaseSunset.opacity(0.85)), lineWidth: 2.5)

        // A neutral ground line under the bands — the fill's phase colors carry the palette now, so
        // the old blue floor would read as a stray fourth color.
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: size.height - 3))
        baseline.addLine(to: CGPoint(x: size.width, y: size.height - 3))
        context.stroke(baseline, with: .color(.white.opacity(0.22)), lineWidth: 3)
    }

    private let fillStep = 10

    private func xPosition(for minute: Int, width: CGFloat) -> CGFloat {
        CGFloat(minute) / 1440.0 * width
    }

    /// The point on the temperature curve at `minute` — shared by the curve stroke and the
    /// per-phase fill so the bands' tops sit exactly on the drawn line.
    private func curvePoint(atMinute minute: Int, size: CGSize) -> CGPoint {
        let kelvin = ColorSchedule.scheduledValue(
            schedule: schedule,
            minuteOfDay: minute
        ) { phase in
            temperature(for: phase).clamped(to: ControlRanges.kelvin)
        }
        return CGPoint(
            x: xPosition(for: minute, width: size.width),
            y: yPosition(for: kelvin, height: size.height)
        )
    }

    private func temperaturePath(size: CGSize) -> Path {
        var path = Path()
        for step in 0...144 {
            let point = curvePoint(atMinute: step * fillStep, size: size)
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
        // A squeezed-out sunset (bedtime began before the sun went down) keeps its handle so
        // the warmth stays tunable, but dimmed — matching its disabled stepper — to say
        // "not part of today's curve".
        let dimmed = handle == .sunset && schedule.sunsetSqueezed

        return Circle()
            .fill(color.opacity(dimmed ? 0.5 : 0.9))
            .frame(width: 20, height: 20)
            .overlay(Circle().stroke(.white.opacity(dimmed ? 0.55 : 1), lineWidth: 2))
            .shadow(color: color.opacity(dimmed ? 0.12 : 0.28), radius: 8, y: 3)
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        update(handle, location: value.location, size: size)
                    }
            )
            .accessibilityLabel("\(phaseLabel(for: handle)) color handle, \(MinuteFormatting.label(for: startMinute(for: handle)))")
            .accessibilityValue(KelvinFormatting.label(for: temperature(for: handle.phase)))
            // VO ↑/↓ adjusts the handle's temperature in the same 100 K steps a drag rounds to;
            // the phase's *time* stays keyboard-editable through the steppers below the chart.
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 100 : -100
                setTemperature((temperature(for: handle.phase) + delta).clamped(to: ControlRanges.kelvin), for: handle)
            }
    }

    private func temperature(for phase: ColorPhase) -> Int {
        switch phase {
        case .daytime:
            dayTemperature
        case .sunset:
            sunsetTemperature
        case .bedtime:
            nightTemperature
        }
    }

    private func setTemperature(_ value: Int, for handle: FluxCurveHandle) {
        switch handle {
        case .day:
            dayTemperature = value
        case .sunset:
            sunsetTemperature = value
        case .night:
            nightTemperature = value
        }
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

    /// The minute-of-day anchor a handle sits on — its horizontal position.
    private func startMinute(for handle: FluxCurveHandle) -> Int {
        switch handle {
        case .day:
            schedule.dayStartMinutes
        case .sunset:
            schedule.sunsetMinutes
        case .night:
            schedule.bedtimeStartMinutes
        }
    }

    private func point(for handle: FluxCurveHandle, in size: CGSize) -> CGPoint {
        CGPoint(
            x: CGFloat(startMinute(for: handle)) / 1440.0 * size.width,
            y: yPosition(for: temperature(for: handle.phase), height: size.height)
        )
    }

    private func update(_ handle: FluxCurveHandle, location: CGPoint, size: CGSize) {
        let kelvin = roundedKelvin(from: location.y, height: size.height)
        setTemperature(kelvin, for: handle)

        guard !timesLocked else {
            return
        }
        let rawMinute = roundedMinutes(from: location.x, width: size.width)
        // Keep the dragged anchor inside the daytime → sunset → bedtime order, so a handle can't be
        // pulled past its neighbors (e.g. sunset dragged before wake snaps back to just after wake).
        let minute = ColorSchedule.clampedStartMinute(
            rawMinute,
            for: handle.phase,
            wake: schedule.dayStartMinutes,
            sunset: schedule.sunsetMinutes,
            bedtime: schedule.bedtimeStartMinutes
        )
        onTimeEdit(handle.phase, minute)
    }

    private func yPosition(for kelvin: Int, height: CGFloat) -> CGFloat {
        let clamped = kelvin.clamped(to: minKelvin...maxKelvin)
        let progress = Double(clamped - minKelvin) / Double(maxKelvin - minKelvin)
        let usable = max(0, height - 2 * verticalInset)
        return verticalInset + usable * CGFloat(1 - progress)
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
        let usable = height - 2 * verticalInset
        guard usable > 0 else {
            return dayTemperature
        }

        let progress = Double((height - verticalInset - y) / usable).clamped(to: 0...1)
        let raw = minKelvin + Int((Double(maxKelvin - minKelvin) * progress).rounded())
        return (Int((Double(raw) / 100.0).rounded()) * 100).clamped(to: ControlRanges.kelvin)
    }
}
