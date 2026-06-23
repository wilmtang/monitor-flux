import CoreGraphics
import Foundation

struct GammaApplySummary: Equatable {
    let appliedCount: Int
    let failedCount: Int
    let message: String
}

enum GammaTemperatureError: LocalizedError {
    case emptyTable
    case coreGraphicsFailure(Int32)

    var errorDescription: String? {
        switch self {
        case .emptyTable:
            "The gamma table was empty."
        case .coreGraphicsFailure(let code):
            "CoreGraphics gamma operation failed with code \(code)."
        }
    }
}

final class GammaTemperatureService {
    private struct GammaTables {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]

        var count: Int {
            min(red.count, green.count, blue.count)
        }
    }

    private var baselines: [CGDirectDisplayID: GammaTables] = [:]
    private var appliedAdjustments: [CGDirectDisplayID: GammaAdjustment] = [:]
    /// The exact tables we last wrote per display, so we can read the LUT back and notice
    /// when another gamma app (Night Shift, f.lux…) has overwritten it.
    private var lastSetTables: [CGDirectDisplayID: GammaTables] = [:]
    private var didStartSession = false
    private let tableSize = 256

    func apply(displays: [DisplayInfo], preferences: AppPreferences) -> GammaApplySummary {
        guard preferences.gammaEnabled else {
            restoreIfNeeded()
            return GammaApplySummary(
                appliedCount: 0,
                failedCount: 0,
                message: "Gamma disabled"
            )
        }

        ensureSessionStarted()

        var applied = 0
        var skipped = 0
        var failed = 0
        let adjustmentsByDisplay = GammaPlan.adjustments(displays: displays, preferences: preferences)
        let enabledDisplayIDs = Set(adjustmentsByDisplay.keys)

        // Restore only displays we previously adjusted that are no longer enabled,
        // so disabling color on one display doesn't flicker the others.
        let droppedIDs = Set(appliedAdjustments.keys).subtracting(enabledDisplayIDs)
        if !droppedIDs.isEmpty {
            restoreDisplays(droppedIDs)
        }

        for display in displays {
            guard let adjustment = adjustmentsByDisplay[display.id] else {
                continue
            }
            if appliedAdjustments[display.id] == adjustment {
                skipped += 1
                continue
            }

            do {
                let baseline = try baselineTables(for: display.id)
                let adjusted = scaledTables(from: baseline, adjustment: adjustment)
                try setTables(adjusted, for: display.id)
                appliedAdjustments[display.id] = adjustment
                applied += 1
            } catch {
                failed += 1
            }
        }

        if adjustmentsByDisplay.isEmpty {
            restoreIfNeeded()
            return GammaApplySummary(
                appliedCount: 0,
                failedCount: 0,
                message: "Gamma neutral"
            )
        }

        if failed == 0 {
            if applied == 0, skipped > 0 {
                return GammaApplySummary(
                    appliedCount: 0,
                    failedCount: 0,
                    message: "Gamma unchanged"
                )
            }
            return GammaApplySummary(
                appliedCount: applied,
                failedCount: failed,
                message: "Applied gamma to \(applied) display\(applied == 1 ? "" : "s")"
            )
        }

        return GammaApplySummary(
            appliedCount: applied,
            failedCount: failed,
            message: "Applied gamma to \(applied), failed \(failed)"
        )
    }

    func restore() {
        CGDisplayRestoreColorSyncSettings()
        baselines.removeAll()
        appliedAdjustments.removeAll()
        lastSetTables.removeAll()
    }

    /// True when the current LUT for any display we've warmed no longer matches what we last
    /// wrote — i.e. another app is also editing gamma and the two are fighting. Reading the
    /// table is cheap and causes no flash. Returns false until we've written at least once.
    func detectsForeignGammaChange(displays: [DisplayInfo]) -> Bool {
        for display in displays {
            guard let lastSet = lastSetTables[display.id],
                  let current = readTables(for: display.id)
            else {
                continue
            }
            if Self.channelsDiffer(current.red, lastSet.red)
                || Self.channelsDiffer(current.green, lastSet.green)
                || Self.channelsDiffer(current.blue, lastSet.blue) {
                return true
            }
        }
        return false
    }

    /// Whether two gamma channels differ beyond `tolerance` anywhere (pure, unit-tested).
    /// The tolerance absorbs the LUT's own quantization of a table we wrote, while a real
    /// foreign warm shifts values far more.
    static func channelsDiffer(
        _ a: [CGGammaValue],
        _ b: [CGGammaValue],
        tolerance: CGGammaValue = 0.02
    ) -> Bool {
        let count = min(a.count, b.count)
        guard count > 0 else {
            return false
        }
        for index in 0..<count where abs(a[index] - b[index]) > tolerance {
            return true
        }
        return false
    }

    /// On the first gamma write of a session, clear any color tables left behind by
    /// a previous run (a crash or force-quit skips `applicationWillTerminate`), so
    /// per-display baselines are captured from clean system tables rather than from
    /// an already-warmed table — which would compound warmth on every launch.
    private func ensureSessionStarted() {
        guard !didStartSession else {
            return
        }

        didStartSession = true
        CGDisplayRestoreColorSyncSettings()
        baselines.removeAll()
        appliedAdjustments.removeAll()
    }

    private func restoreDisplays(_ ids: Set<CGDirectDisplayID>) {
        var didGlobalRestore = false
        for id in ids {
            if let baseline = baselines[id] {
                try? setTables(baseline, for: id)
            } else if !didGlobalRestore {
                CGDisplayRestoreColorSyncSettings()
                didGlobalRestore = true
            }
            baselines[id] = nil
            appliedAdjustments[id] = nil
            lastSetTables[id] = nil
        }
    }

    private func restoreIfNeeded() {
        guard !baselines.isEmpty || !appliedAdjustments.isEmpty else {
            return
        }

        restore()
    }

    private func baselineTables(for displayID: CGDirectDisplayID) throws -> GammaTables {
        if let existing = baselines[displayID] {
            return existing
        }

        let baseline = readTables(for: displayID) ?? linearTables()
        baselines[displayID] = baseline
        return baseline
    }

    private func readTables(for displayID: CGDirectDisplayID) -> GammaTables? {
        var red = Array(repeating: CGGammaValue(0), count: tableSize)
        var green = Array(repeating: CGGammaValue(0), count: tableSize)
        var blue = Array(repeating: CGGammaValue(0), count: tableSize)
        var sampleCount: UInt32 = 0

        let error = red.withUnsafeMutableBufferPointer { redPointer in
            green.withUnsafeMutableBufferPointer { greenPointer in
                blue.withUnsafeMutableBufferPointer { bluePointer in
                    CGGetDisplayTransferByTable(
                        displayID,
                        UInt32(tableSize),
                        redPointer.baseAddress,
                        greenPointer.baseAddress,
                        bluePointer.baseAddress,
                        &sampleCount
                    )
                }
            }
        }

        guard error == .success, sampleCount > 0 else {
            return nil
        }

        let count = min(Int(sampleCount), tableSize)
        return GammaTables(
            red: Array(red.prefix(count)),
            green: Array(green.prefix(count)),
            blue: Array(blue.prefix(count))
        )
    }

    private func setTables(_ tables: GammaTables, for displayID: CGDirectDisplayID) throws {
        let count = tables.count
        guard count > 0 else {
            throw GammaTemperatureError.emptyTable
        }

        let error = tables.red.withUnsafeBufferPointer { redPointer in
            tables.green.withUnsafeBufferPointer { greenPointer in
                tables.blue.withUnsafeBufferPointer { bluePointer in
                    CGSetDisplayTransferByTable(
                        displayID,
                        UInt32(count),
                        redPointer.baseAddress,
                        greenPointer.baseAddress,
                        bluePointer.baseAddress
                    )
                }
            }
        }

        guard error == .success else {
            throw GammaTemperatureError.coreGraphicsFailure(error.rawValue)
        }
        lastSetTables[displayID] = tables
    }

    private func scaledTables(from baseline: GammaTables, adjustment: GammaAdjustment) -> GammaTables {
        let multipliers = GammaCompositor.multipliers(for: adjustment)
        return GammaTables(
            red: baseline.red.map { value in
                CGGammaValue(GammaCompositor.adjustedValue(
                    Double(value),
                    channelMultiplier: multipliers.red,
                    brightnessPercent: adjustment.brightnessPercent,
                    contrastPercent: adjustment.contrastPercent
                ))
            },
            green: baseline.green.map { value in
                CGGammaValue(GammaCompositor.adjustedValue(
                    Double(value),
                    channelMultiplier: multipliers.green,
                    brightnessPercent: adjustment.brightnessPercent,
                    contrastPercent: adjustment.contrastPercent
                ))
            },
            blue: baseline.blue.map { value in
                CGGammaValue(GammaCompositor.adjustedValue(
                    Double(value),
                    channelMultiplier: multipliers.blue,
                    brightnessPercent: adjustment.brightnessPercent,
                    contrastPercent: adjustment.contrastPercent
                ))
            }
        )
    }

    private func linearTables() -> GammaTables {
        var red: [CGGammaValue] = []
        var green: [CGGammaValue] = []
        var blue: [CGGammaValue] = []

        for index in 0..<tableSize {
            let value = CGGammaValue(Double(index) / Double(tableSize - 1))
            red.append(value)
            green.append(value)
            blue.append(value)
        }

        return GammaTables(red: red, green: green, blue: blue)
    }
}
