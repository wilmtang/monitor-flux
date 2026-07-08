// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import CoreGraphics
import Foundation

enum HardwareDDCError: LocalizedError, Sendable {
    case nativeAndFallbackFailed(native: String, fallback: String)

    var errorDescription: String? {
        switch self {
        case .nativeAndFallbackFailed(let native, let fallback):
            "Native DDC failed: \(native). Fallback failed: \(fallback)"
        }
    }
}

struct HardwareDDCBackend: Sendable {
    #if arch(arm64)
    private let arm64 = Arm64DDCBackend()
    #else
    private let native = NativeDDCBackend()
    #endif
    private let commandLine = DDCCommandLineBackend()

    private var primaryName: String {
        #if arch(arm64)
        "Native IOAVService"
        #else
        "Native IOKit"
        #endif
    }

    var status: DDCBackendStatus {
        if commandLine.status.isAvailable {
            return DDCBackendStatus(
                isAvailable: true,
                toolName: "\(primaryName) + \(commandLine.status.toolName)",
                toolPath: commandLine.status.toolPath,
                message: "Native DDC, fallback \(commandLine.status.toolName)"
            )
        }

        return DDCBackendStatus(
            isAvailable: true,
            toolName: primaryName,
            toolPath: nil,
            message: "Native DDC"
        )
    }

    /// Drop any cached per-display I2C service handles. Called when the display layout
    /// changes so a re-plugged monitor re-resolves instead of writing to a stale handle.
    func invalidateServiceCache() {
        #if arch(arm64)
        Arm64DDCBackend.invalidateServiceCache()
        #endif
    }

    /// Which external displays can actually do DDC — a non-destructive capability check (no
    /// monitor round-trip). On Apple Silicon it's a global IOAVService→display match (so a
    /// non-DDC monitor beside a real one isn't credited a borrowed service); on Intel there's no
    /// equally cheap probe, so assume every external is capable (the prior, optimistic behavior).
    func ddcCapableDisplays(_ displays: [DisplayInfo]) -> Set<CGDirectDisplayID> {
        #if arch(arm64)
        return Arm64DDCBackend.capableDisplays(among: displays)
        #else
        return Set(displays.filter { !$0.isBuiltIn }.map(\.id))
        #endif
    }

    func setBrightness(_ value: Int, display: DisplayInfo, fallbackIndex: Int) throws {
        try perform(
            primary: { try primarySetBrightness(value, display: display) },
            fallback: { try commandLine.setBrightness(value, displayIndex: fallbackIndex) }
        )
    }

    func setContrast(_ value: Int, display: DisplayInfo, fallbackIndex: Int) throws {
        try perform(
            primary: { try primarySetContrast(value, display: display) },
            fallback: { try commandLine.setContrast(value, displayIndex: fallbackIndex) }
        )
    }

    /// Volume has no `ddcctl` fallback (Intel-only tool, and volume support varies),
    /// so it uses the native architecture backend only.
    func setVolume(_ value: Int, display: DisplayInfo) throws {
        #if arch(arm64)
        try arm64.setVolume(value, display: display)
        #else
        try native.setVolume(value, display: display)
        #endif
    }

    private func primarySetBrightness(_ value: Int, display: DisplayInfo) throws {
        #if arch(arm64)
        try arm64.setBrightness(value, display: display)
        #else
        try native.setBrightness(value, display: display)
        #endif
    }

    private func primarySetContrast(_ value: Int, display: DisplayInfo) throws {
        #if arch(arm64)
        try arm64.setContrast(value, display: display)
        #else
        try native.setContrast(value, display: display)
        #endif
    }

    /// Try the native (architecture-specific) backend, then `ddcctl` if it exists,
    /// reporting both errors when neither works.
    private func perform(primary: () throws -> Void, fallback: () throws -> Void) throws {
        do {
            try primary()
        } catch let primaryError {
            guard commandLine.status.isAvailable else {
                throw primaryError
            }
            do {
                try fallback()
            } catch let fallbackError {
                throw HardwareDDCError.nativeAndFallbackFailed(
                    native: primaryError.localizedDescription,
                    fallback: fallbackError.localizedDescription
                )
            }
        }
    }
}
