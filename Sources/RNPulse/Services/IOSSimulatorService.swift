import AppKit
import Foundation
import ImageIO

struct IOSLaunchResult {
    let app: IOSRunningApp
    let startupMS: Double?
}

struct IOSSimulatorService {
    private let runner = ProcessRunner()
    private let performanceService = IOSPerformanceService()

    func discover() async throws -> [Device] {
        let result = try await runner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "list", "devices", "available", "--json"],
            timeout: 10
        )

        guard result.exitCode == 0 else {
            throw NSError(
                domain: "RNPulse.iOS",
                code: Int(result.exitCode),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        result.stderr.isEmpty ? "simctl failed." : result.stderr
                ]
            )
        }

        return try parseDevices(result.stdout)
    }

    func boot(deviceID: String) async throws {
        let result = try await runner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "boot", deviceID],
            timeout: 30
        )

        // simctl returns a non-zero status when the device is already booted.
        if result.exitCode != 0,
           !result.stderr.localizedCaseInsensitiveContains("already booted") {
            throw NSError(
                domain: "RNPulse.iOS",
                code: Int(result.exitCode),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        result.stderr.isEmpty
                        ? "Unable to boot the simulator."
                        : result.stderr
                ]
            )
        }

        let bootStatus = try await runner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "bootstatus", deviceID, "-b"],
            timeout: 60
        )

        guard bootStatus.exitCode == 0 else {
            throw NSError(
                domain: "RNPulse.iOS",
                code: Int(bootStatus.exitCode),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        bootStatus.stderr.isEmpty
                        ? "Simulator did not finish booting."
                        : bootStatus.stderr
                ]
            )
        }
    }

    func openSimulator() async throws {
        let result = try await runner.run(
            "/usr/bin/open",
            arguments: ["-a", "Simulator"],
            timeout: 10
        )

        guard result.exitCode == 0 else {
            throw NSError(
                domain: "RNPulse.iOS",
                code: Int(result.exitCode),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        result.stderr.isEmpty
                        ? "Unable to open Simulator."
                        : result.stderr
                ]
            )
        }
    }

    func bootAndOpen(deviceID: String) async throws {
        try await boot(deviceID: deviceID)
        try await openSimulator()
    }

    func listInstalledApps(deviceID: String) async throws -> [IOSInstalledApp] {
        let result = try await runner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "listapps", deviceID],
            timeout: 15
        )

        guard result.exitCode == 0 else {
            throw NSError(
                domain: "RNPulse.iOS",
                code: Int(result.exitCode),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        result.stderr.isEmpty
                        ? "Unable to inspect installed simulator apps."
                        : result.stderr
                ]
            )
        }

        return try parseInstalledApps(result.stdout)
    }

    func terminateApp(deviceID: String, bundleID: String) async throws {
        let result = try await runner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "terminate", deviceID, bundleID],
            timeout: 10
        )

        // Already-stopped applications can be reported as an error. That is
        // harmless for the cold-launch workflow.
        if result.exitCode != 0 &&
           !result.stderr.localizedCaseInsensitiveContains("not running") {
            throw NSError(
                domain: "RNPulse.iOS",
                code: Int(result.exitCode),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        result.stderr.isEmpty
                        ? "Unable to terminate the app."
                        : result.stderr
                ]
            )
        }
    }

    func launchApp(
        deviceID: String,
        bundleID: String,
        measureFirstFrame: Bool = true
    ) async throws -> IOSLaunchResult {
        let isBooted = try await isDeviceBooted(deviceID: deviceID)
        guard isBooted else {
            throw NSError(
                domain: "RNPulse.iOS",
                code: 10,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Boot the simulator before launching an app."
                ]
            )
        }

        // Make launch timing reproducible: terminate the current instance and
        // give SpringBoard a moment to settle before starting the new launch.
        try? await terminateApp(deviceID: deviceID, bundleID: bundleID)
        try? await Task.sleep(for: .milliseconds(250))

        let baseline = measureFirstFrame ? try? await performanceService.captureScreenshot(deviceID: deviceID) : nil
        let clock = ContinuousClock.now

        let result = try await runner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "launch", deviceID, bundleID],
            timeout: 20
        )

        guard result.exitCode == 0 else {
            throw NSError(
                domain: "RNPulse.iOS",
                code: Int(result.exitCode),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        result.stderr.isEmpty
                        ? "Unable to launch (bundleID)."
                        : result.stderr
                ]
            )
        }

        let runningApp = try await waitForRunningApp(
            deviceID: deviceID,
            bundleID: bundleID
        )

        var startupMS: Double?

        if measureFirstFrame, let baseline {
            startupMS = await waitForFirstVisibleFrame(
                deviceID: deviceID,
                baseline: baseline,
                startedAt: clock
            )
        }

        if startupMS == nil {
            startupMS = Self.durationMS(since: clock)
        }

        return IOSLaunchResult(
            app: runningApp,
            startupMS: startupMS
        )
    }

    private func isDeviceBooted(deviceID: String) async throws -> Bool {
        let result = try await runner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "get_state", deviceID],
            timeout: 10
        )

        return result.exitCode == 0 &&
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveContains("booted")
    }

    private func waitForRunningApp(
        deviceID: String,
        bundleID: String,
        timeout: Duration = .seconds(8)
    ) async throws -> IOSRunningApp {
        let deadline = ContinuousClock.now + timeout

        while ContinuousClock.now < deadline {
            if let app = try? await discoverRunningApps(deviceID: deviceID)
                .first(where: { $0.bundleID == bundleID }) {
                return app
            }

            try? await Task.sleep(for: .milliseconds(50))
        }

        throw NSError(
            domain: "RNPulse.iOS",
            code: 11,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The app launched but its process could not be detected."
            ]
        )
    }

    private func waitForFirstVisibleFrame(
        deviceID: String,
        baseline: Data,
        startedAt: ContinuousClock.Instant
    ) async -> Double? {
        let deadline = ContinuousClock.now + .seconds(10)

        while ContinuousClock.now < deadline {
            if let screenshot = try? await performanceService.captureScreenshot(
                deviceID: deviceID
            ),
            imagesLookDifferent(baseline, screenshot) {
                return Self.durationMS(since: startedAt)
            }

            try? await Task.sleep(for: .milliseconds(80))
        }

        return nil
    }

    private func parseInstalledApps(_ output: String) throws -> [IOSInstalledApp] {
        let data = Data(output.utf8)

        guard let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw NSError(
                domain: "RNPulse.iOS",
                code: 12,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unable to parse the installed application list from simctl."
                ]
            )
        }

        return plist.compactMap { bundleID, rawValue in
            guard let info = rawValue as? [String: Any] else {
                return nil
            }

            let displayName =
                (info["CFBundleDisplayName"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? (info["CFBundleName"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? bundleID

            let executable = info["CFBundleExecutable"] as? String

            return IOSInstalledApp(
                id: bundleID,
                bundleID: bundleID,
                displayName: displayName.isEmpty ? bundleID : displayName,
                executableName: executable
            )
        }
        .sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func imagesLookDifferent(_ first: Data, _ second: Data) -> Bool {
        guard let firstCG = Self.makeCGImage(from: first),
              let secondCG = Self.makeCGImage(from: second) else {
            return first != second
        }

        let size = 48
        guard let firstPixels = Self.samplePixels(firstCG, size: size),
              let secondPixels = Self.samplePixels(secondCG, size: size),
              firstPixels.count == secondPixels.count else {
            return first != second
        }

        var difference = 0.0

        for index in firstPixels.indices {
            difference += abs(
                Double(firstPixels[index]) - Double(secondPixels[index])
            )
        }

        let meanDifference =
            difference / Double(max(firstPixels.count, 1))

        // JPEG noise alone generally stays well below this threshold. We only
        // need to detect that the visible screen changed from SpringBoard to
        // the application's first rendered frame.
        return meanDifference > 6.0
    }

    private static func makeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            nil
        ) else {
            return nil
        }

        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func samplePixels(
        _ image: CGImage,
        size: Int
    ) -> [UInt8]? {
        let bytesPerRow = size
        var pixels = [UInt8](repeating: 0, count: size * size)

        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .low
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: size, height: size)
        )

        return pixels
    }

    private static func durationMS(
        since start: ContinuousClock.Instant
    ) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) * 1000.0
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
    }

    private struct SimctlResponse: Decodable {
        let devices: [String: [SimctlDevice]]
    }

    private struct SimctlDevice: Decodable {
        let state: String
        let isAvailable: Bool?
        let name: String
        let udid: String
        let deviceTypeIdentifier: String?
    }

    private func parseDevices(_ output: String) throws -> [Device] {
        let data = Data(output.utf8)
        let response = try JSONDecoder().decode(SimctlResponse.self, from: data)

        return response.devices.flatMap { runtime, devices in
            let version = runtime
                .split(separator: ".")
                .last
                .map(String.init)

            return devices.compactMap { simulator -> Device? in
                guard simulator.isAvailable != false else { return nil }

                let state: DeviceState = switch simulator.state.lowercased() {
                case "booted": .booted
                case "shutdown": .shutdown
                default: .unavailable
                }

                return Device(
                    id: simulator.udid,
                    name: simulator.name,
                    platform: .iOS,
                    osVersion: version,
                    state: state,
                    modelIdentifier: simulator.deviceTypeIdentifier
                )
            }
        }
    }

    private func discoverRunningApps(deviceID: String) async throws -> [IOSRunningApp] {
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
                    NSLocalizedDescriptionKey:
                        result.stderr.isEmpty
                        ? "Unable to inspect running simulator processes."
                        : result.stderr
                ]
            )
        }

        var apps: [IOSRunningApp] = []
        var seen = Set<String>()

        for line in result.stdout.split(separator: "\n") {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 3,
                  let pid = Int(columns[0]),
                  pid > 0 else {
                continue
            }

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

            let processName =
                bundleID.split(separator: ".").last.map(String.init)
                ?? bundleID

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

        return apps
    }
}
