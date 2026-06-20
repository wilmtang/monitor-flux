import Foundation

struct HardwareDDCBackend: Sendable {
    private let native = NativeDDCBackend()
    private let commandLine = DDCCommandLineBackend()

    var status: DDCBackendStatus {
        if commandLine.status.isAvailable {
            return DDCBackendStatus(
                isAvailable: true,
                toolName: "Native IOKit + \(commandLine.status.toolName)",
                toolPath: commandLine.status.toolPath,
                message: "Native DDC, fallback \(commandLine.status.toolName)"
            )
        }

        return DDCBackendStatus(
            isAvailable: true,
            toolName: "Native IOKit",
            toolPath: nil,
            message: "Native DDC"
        )
    }

    func setBrightness(_ value: Int, display: DisplayInfo, fallbackIndex: Int) throws {
        do {
            try native.setBrightness(value, display: display)
        } catch {
            guard commandLine.status.isAvailable else {
                throw error
            }
            try commandLine.setBrightness(value, displayIndex: fallbackIndex)
        }
    }

    func setContrast(_ value: Int, display: DisplayInfo, fallbackIndex: Int) throws {
        do {
            try native.setContrast(value, display: display)
        } catch {
            guard commandLine.status.isAvailable else {
                throw error
            }
            try commandLine.setContrast(value, displayIndex: fallbackIndex)
        }
    }
}
