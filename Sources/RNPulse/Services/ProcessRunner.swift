import Foundation

enum ProcessRunnerError: LocalizedError {
    case executableNotFound(String)
    case launchFailed(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let executable):
            "Executable not found: \(executable)"
        case .launchFailed(let message):
            "Failed to launch process: \(message)"
        case .timedOut(let executable):
            "Process timed out: \(executable)"
        }
    }
}

final class ProcessRunner {
    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    func run(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) async throws -> Result {
        guard let executableURL = resolveExecutable(executable) else {
            throw ProcessRunnerError.executableNotFound(executable)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            if !environment.isEmpty {
                var processEnvironment = ProcessInfo.processInfo.environment
                environment.forEach { processEnvironment[$0.key] = $0.value }
                process.environment = processEnvironment
            }

            let lock = NSLock()
            var didResume = false

            func finish(_ result: Result) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: result)
            }

            func fail(_ error: Error) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                continuation.resume(throwing: error)
            }

            do {
                try process.run()
            } catch {
                fail(ProcessRunnerError.launchFailed(error.localizedDescription))
                return
            }

            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    process.terminate()
                    fail(ProcessRunnerError.timedOut(executable))
                }
            }

            DispatchQueue.global().async {
                process.waitUntilExit()
                let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                finish(
                    Result(
                        exitCode: process.terminationStatus,
                        stdout: String(data: stdout, encoding: .utf8) ?? "",
                        stderr: String(data: stderr, encoding: .utf8) ?? ""
                    )
                )
            }
        }
    }

    func stream(
        _ executable: String,
        arguments: [String] = [],
        onOutput: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> Int32 {
        guard let executableURL = resolveExecutable(executable) else {
            throw ProcessRunnerError.executableNotFound(executable)
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            onOutput(output, false)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            onOutput(output, true)
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        return process.terminationStatus
    }

    private func resolveExecutable(_ executable: String) -> URL? {
        if executable.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: executable)
                ? URL(fileURLWithPath: executable)
                : nil
        }

        let commonPaths = [
            "/opt/homebrew/bin/\(executable)",
            "/usr/local/bin/\(executable)",
            "/usr/bin/\(executable)",
            "/bin/\(executable)"
        ]

        if let path = commonPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        let pathResult = try? ProcessRunner().runSync("/usr/bin/which", arguments: [executable])
        if let pathResult, pathResult.exitCode == 0 {
            let path = pathResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }

    private func runSync(_ executable: String, arguments: [String]) throws -> Result {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return Result(
            exitCode: process.terminationStatus,
            stdout: String(data: data, encoding: .utf8) ?? "",
            stderr: ""
        )
    }
}
