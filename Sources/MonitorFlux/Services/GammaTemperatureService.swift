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

        var applied = 0
        var skipped = 0
        var failed = 0
        let adjustmentsByDisplay = GammaPlan.adjustments(displays: displays, preferences: preferences)
        let enabledDisplayIDs = Set(adjustmentsByDisplay.keys)

        if !Set(appliedAdjustments.keys).isSubset(of: enabledDisplayIDs) {
            CGDisplayRestoreColorSyncSettings()
            baselines.removeAll()
            appliedAdjustments.removeAll()
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
