import Foundation

struct AndroidPerformanceService {
    private let runner = ProcessRunner()

    func capture(packageId: String, deviceId: String) async throws -> PerformanceSnapshot {
        let pid = try await processID(packageId: packageId, deviceId: deviceId)
        async let cpu = cpuPercent(pid: pid, deviceId: deviceId)
        async let memory = memoryMB(packageId: packageId, deviceId: deviceId)
        async let fps = fps(packageId: packageId, deviceId: deviceId)

        return PerformanceSnapshot(
            cpuPercent: try await cpu,
            memoryMB: try await memory,
            fps: try await fps
        )
    }

    private func processID(packageId: String, deviceId: String) async throws -> String {
        let result = try await shell(["-s", deviceId, "shell", "pidof", packageId], timeout: 5)
        guard result.exitCode == 0 else {
            throw performanceError("Unable to resolve PID for \(packageId): \(result.stderr)")
        }

        guard let pid = result.stdout
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init),
            !pid.isEmpty else {
            throw performanceError("No running process found for \(packageId).")
        }

        return pid
    }

    private func cpuPercent(pid: String, deviceId: String) async throws -> Double? {
        let result = try await shell(
            ["-s", deviceId, "shell", "top", "-b", "-n", "1", "-p", pid],
            timeout: 5
        )

        guard result.exitCode == 0 else { return nil }

        for line in result.stdout.split(separator: "\n") {
            let columns = line.split(whereSeparator: { $0.isWhitespace })
            guard let processIndex = columns.firstIndex(where: { $0 == Substring(pid) }) else {
                continue
            }

            // Typical Android top output has CPU percentage immediately before PID.
            if processIndex > 0, let value = Double(columns[processIndex - 1]) {
                return value
            }
        }

        return nil
    }

    private func memoryMB(packageId: String, deviceId: String) async throws -> Double? {
        let result = try await shell(
            ["-s", deviceId, "shell", "dumpsys", "meminfo", packageId],
            timeout: 8
        )

        guard result.exitCode == 0 else { return nil }

        for line in result.stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("TOTAL") else { continue }

            let values = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard values.count >= 2, let kb = Double(values[1]) else { continue }
            return kb / 1024.0
        }

        return nil
    }

    private func fps(packageId: String, deviceId: String) async throws -> Double? {
        let result = try await shell(
            ["-s", deviceId, "shell", "dumpsys", "gfxinfo", packageId],
            timeout: 8
        )

        guard result.exitCode == 0 else { return nil }

        // gfxinfo's profile data differs between Android releases.
        // Prefer an explicit total frames / total time pair when available.
        var frames: Double?
        var totalTimeMS: Double?

        for line in result.stdout.split(separator: "\n") {
            let lower = line.lowercased()

            if lower.contains("total frames rendered") {
                frames = parseFirstNumber(line)
            } else if lower.contains("total time") && lower.contains("ms") {
                totalTimeMS = parseFirstNumber(line)
            }
        }

        guard let frames, let totalTimeMS, totalTimeMS > 0 else {
            return nil
        }

        return frames / (totalTimeMS / 1000.0)
    }

    private func parseFirstNumber(_ line: Substring) -> Double? {
        line.split(whereSeparator: { $0.isWhitespace || $0 == ":" })
            .compactMap { Double($0.filter { $0.isNumber || $0 == "." }) }
            .first
    }

    private func shell(_ arguments: [String], timeout: TimeInterval) async throws -> ProcessRunner.Result {
        try await runner.run("adb", arguments: arguments, timeout: timeout)
    }

    private func performanceError(_ message: String) -> NSError {
        NSError(
            domain: "RNPulse.Performance",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
