import Foundation

struct DDCBackendStatus: Equatable, Sendable {
    let isAvailable: Bool
    let toolName: String
    let toolPath: String?
    let message: String

    static let unavailable = DDCBackendStatus(
        isAvailable: false,
        toolName: "None",
        toolPath: nil,
        message: "No DDC command backend found"
    )
}

enum DDCControlKind: Sendable {
    case brightness
    case contrast
}

enum DDCBackendError: LocalizedError, Sendable {
    case missingTool
    case invalidDisplayIndex
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingTool:
            "No DDC command backend is installed."
        case .invalidDisplayIndex:
            "The DDC display index must be greater than zero."
        case .commandFailed(let output):
            output.isEmpty ? "The DDC command failed." : output
        }
    }
}

struct DDCCommandLineBackend: Sendable {
    private enum Tool: Sendable {
        case ddcctl(URL)

        var name: String {
            switch self {
            case .ddcctl:
                "ddcctl"
            }
        }

        var path: String {
            switch self {
            case .ddcctl(let url):
                url.path
            }
        }

        func arguments(kind: DDCControlKind, value: Int, displayIndex: Int) -> [String] {
            switch self {
            case .ddcctl:
                switch kind {
                case .brightness:
                    ["-d", "\(displayIndex)", "-b", "\(value)"]
                case .contrast:
                    ["-d", "\(displayIndex)", "-c", "\(value)"]
                }
            }
        }
    }

    private let tool: Tool?

    init() {
        tool = Self.detectTool()
    }

    var status: DDCBackendStatus {
        guard let tool else {
            return .unavailable
        }

        return DDCBackendStatus(
            isAvailable: true,
            toolName: tool.name,
            toolPath: tool.path,
            message: "Using \(tool.name)"
        )
    }

    func setBrightness(_ value: Int, displayIndex: Int) throws {
        try run(kind: .brightness, value: value, displayIndex: displayIndex)
    }

    func setContrast(_ value: Int, displayIndex: Int) throws {
        try run(kind: .contrast, value: value, displayIndex: displayIndex)
    }

    private func run(kind: DDCControlKind, value: Int, displayIndex: Int) throws {
        guard let tool else {
            throw DDCBackendError.missingTool
        }
        guard displayIndex > 0 else {
            throw DDCBackendError.invalidDisplayIndex
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool.path)
        process.arguments = tool.arguments(
            kind: kind,
            value: value.clamped(to: 0...100),
            displayIndex: displayIndex
        )

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw DDCBackendError.commandFailed(output)
        }
    }

    private static func detectTool() -> Tool? {
        let candidates = executableCandidates(named: "ddcctl")
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return .ddcctl(candidate)
        }
        return nil
    }

    private static func executableCandidates(named name: String) -> [URL] {
        var paths = Set<String>()
        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for folder in pathValue.split(separator: ":") {
            paths.insert(String(folder))
        }
        paths.formUnion(["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])

        return paths
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .sorted { $0.path < $1.path }
    }
}
