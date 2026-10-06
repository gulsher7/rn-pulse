import Foundation

struct IOSPerformanceService {
    private let runner = ProcessRunner()

    func discoverRunningApps(deviceID: String) async throws -> [IOSRunningApp] {
        let result = try await runner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "spawn", deviceID, "launchctl", "list"],
            timeout: 10
        )

        guard result.exitCode == 0 else {
            throw NSError(
                domain: "RNPulse.iOS",
                code: Int(result.exitCode),
                userInfo: [
                    NSLocalizedDescriptionKey: result.stderr.isEmpty
                        ? "Unable to inspect running simulator processes."
                        : result.stderr
                ]
            )
        }

        return parseRunningApps(result.stdout)
    }

    func capture(
        deviceID: String,
        app: IOSRunningApp
    ) async throws -> PerformanceSnapshot {
        let result = try await runner.run(
            "/usr/bin/xcrun",
            arguments: [
                "simctl",
                "spawn",
                deviceID,
                "ps",
                "-p",
                String(app.processID),
                "-o",
                "pcpu=,rss="
            ],
            timeout: 5
        )

        guard result.exitCode == 0 else {
            throw NSError(
                domain: "RNPulse.iOS",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: result.stderr]
            )
        }

        let values = result.stdout
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Double($0) }

        guard values.count >= 2 else {
            throw NSError(
                domain: "RNPulse.iOS",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "The selected app is no longer running."
                ]
            )
        }

        // ps reports CPU as a percentage and RSS as KB.
        return PerformanceSnapshot(
            cpuPercent: values[0],
            memoryMB: values[1] / 1024.0
        )
    }

    func captureScreenshot(deviceID: String) async throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-pulse-screenshots", isDirectory: true)

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let fileURL = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")

        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let result = try await runner.run(
            "/usr/bin/xcrun",
            arguments: [
                "simctl",
                "io",
                deviceID,
                "screenshot",
                "--type=jpeg",
                fileURL.path
            ],
            timeout: 5
        )

        guard result.exitCode == 0 else {
            throw NSError(
                domain: "RNPulse.iOS",
                code: Int(result.exitCode),
                userInfo: [
                    NSLocalizedDescriptionKey: result.stderr.isEmpty
                        ? "Unable to capture the simulator screen."
                        : result.stderr
                ]
            )
        }

        return try Data(contentsOf: fileURL)
    }

    private func parseRunningApps(_ output: String) -> [IOSRunningApp] {
        var apps: [IOSRunningApp] = []
        var seen = Set<String>()

        for line in output.split(separator: "\n") {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 3 else { continue }

            guard let pid = Int(columns[0]), pid > 0 else { continue }

            let label = String(columns[2])

            guard let prefixRange = label.range(of: "UIKitApplication:") else {
                continue
            }

            let remainder = label[prefixRange.upperBound...]
            guard let bracket = remainder.firstIndex(of: "[") else {
                continue
            }

            let bundleID = String(remainder[..<bracket])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !bundleID.isEmpty, !seen.contains(bundleID) else {
                continue
            }

            let processName = bundleID.split(separator: ".").last.map(String.init) ?? bundleID

            apps.append(
                IOSRunningApp(
                    id: bundleID,
                    bundleID: bundleID,
                    processID: pid,
                    processName: processName
                )
            )
            seen.insert(bundleID)
        }

        return apps.sorted {
            $0.bundleID.localizedCaseInsensitiveCompare($1.bundleID) == .orderedAscending
        }
    }
}
