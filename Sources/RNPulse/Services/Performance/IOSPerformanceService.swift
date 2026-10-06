import Foundation

final class IOSPerformanceService {
    private let runner = ProcessRunner()
    private var mirrorProcess: Process?
    private var mirrorInputPipe: Pipe?
    private var mirrorOutputPipe: Pipe?
    private var mirrorErrorPipe: Pipe?

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
        // Simulator app processes are host macOS processes. Query the host
        // process directly instead of asking the simulator runtime to execute ps.
        let result = try await runner.run(
            "/bin/ps",
            arguments: [
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
                userInfo: [
                    NSLocalizedDescriptionKey: result.stderr.isEmpty
                        ? "Unable to inspect the simulator app process."
                        : result.stderr
                ]
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
                    NSLocalizedDescriptionKey: "The selected app process is no longer running."
                ]
            )
        }

        return PerformanceSnapshot(
            cpuPercent: values[0],
            memoryMB: values[1] / 1024.0
        )
    }

    @discardableResult
    func startMirror(
        deviceID: String,
        onFrame: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) -> Bool {
        stopMirror()

        guard let ffmpegURL = resolveFFmpeg() else {
            onError("ffmpeg was not found. Falling back to Simulator screenshots.")
            return false
        }

        let recordProcess = Process()
        let ffmpegProcess = Process()

        let recordOutput = Pipe()
        let ffmpegInput = Pipe()
        let ffmpegOutput = Pipe()
        let ffmpegError = Pipe()

        recordProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        recordProcess.arguments = [
            "simctl",
            "io",
            deviceID,
            "recordVideo",
            "--type=fmp4",
            "-"
        ]
        recordProcess.standardOutput = recordOutput
        recordProcess.standardError = Pipe()

        ffmpegProcess.executableURL = ffmpegURL
        ffmpegProcess.arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-f", "mp4",
            "-i", "pipe:0",
            "-an",
            "-vf", "fps=15",
            "-c:v", "mjpeg",
            "-q:v", "6",
            "-f", "image2pipe",
            "pipe:1"
        ]
        ffmpegProcess.standardInput = ffmpegInput
        ffmpegProcess.standardOutput = ffmpegOutput
        ffmpegProcess.standardError = ffmpegError

        recordOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            try? ffmpegInput.fileHandleForWriting.write(contentsOf: data)
        }

        ffmpegOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Self.consumeJPEGBytes(data, onFrame: onFrame)
        }

        ffmpegError.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let message = String(data: data, encoding: .utf8),
                  !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            onError(message)
        }

        do {
            try ffmpegProcess.run()
            try recordProcess.run()
        } catch {
            recordOutput.fileHandleForReading.readabilityHandler = nil
            ffmpegOutput.fileHandleForReading.readabilityHandler = nil
            ffmpegError.fileHandleForReading.readabilityHandler = nil
            if recordProcess.isRunning { recordProcess.terminate() }
            if ffmpegProcess.isRunning { ffmpegProcess.terminate() }
            onError("Unable to start fast simulator mirror: \(error.localizedDescription)")
            return false
        }

        mirrorProcess = recordProcess
        mirrorInputPipe = ffmpegInput
        mirrorOutputPipe = ffmpegOutput
        mirrorErrorPipe = ffmpegError

        return true
    }

    func stopMirror() {
        mirrorInputPipe?.fileHandleForWriting.closeFile()
        mirrorOutputPipe?.fileHandleForReading.readabilityHandler = nil
        mirrorErrorPipe?.fileHandleForReading.readabilityHandler = nil

        if let process = mirrorProcess, process.isRunning {
            process.terminate()
        }

        mirrorProcess = nil
        mirrorInputPipe = nil
        mirrorOutputPipe = nil
        mirrorErrorPipe = nil
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

    private func resolveFFmpeg() -> URL? {
        let paths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]

        return paths.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }.map(URL.init(fileURLWithPath:))
    }

    private static func consumeJPEGBytes(
        _ data: Data,
        onFrame: @escaping @Sendable (Data) -> Void
    ) {
        JPEGFrameAccumulator.shared.append(data, onFrame: onFrame)
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

private final class JPEGFrameAccumulator {
    static let shared = JPEGFrameAccumulator()

    private let lock = NSLock()
    private var buffer = Data()

    func append(
        _ data: Data,
        onFrame: @escaping @Sendable (Data) -> Void
    ) {
        lock.lock()
        buffer.append(data)

        while let start = buffer.range(of: Data([0xFF, 0xD8])),
              let end = buffer.range(
                of: Data([0xFF, 0xD9]),
                options: [],
                in: start.lowerBound..<buffer.endIndex
              ) {
            let frameEnd = end.upperBound
            let frame = buffer.subdata(in: start.lowerBound..<frameEnd)
            buffer.removeSubrange(0..<frameEnd)
            lock.unlock()

            onFrame(frame)

            lock.lock()
        }

        if buffer.count > 8 * 1024 * 1024 {
            buffer.removeAll(keepingCapacity: true)
        }

        lock.unlock()
    }
}
