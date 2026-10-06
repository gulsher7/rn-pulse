import Foundation

final class IOSPerformanceService {
    private let runner = ProcessRunner()

    private var mirrorProcess: Process?
    private var mirrorDecoderProcess: Process?
    private var mirrorInputPipe: Pipe?
    private var mirrorOutputPipe: Pipe?
    private var mirrorErrorPipe: Pipe?

    private var fpsProcess: Process?
    private var fpsTraceURL: URL?

    private let fpsLock = NSLock()
    private var latestFPS: Double?

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
            memoryMB: values[1] / 1024.0,
            fps: currentFPS()
        )
    }

    // Core Animation FPS is collected by Instruments/xctrace rather than by
    // measuring the simulator mirror stream. The mirror is only a preview and
    // must never be treated as the app's FPS.
    @discardableResult
    func startFPSRecording(
        deviceID: String,
        app: IOSRunningApp,
        durationSeconds: Int = 5,
        onResult: @escaping @Sendable (Double) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) -> Bool {
        stopFPSRecording()
        setLatestFPS(nil)

        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-pulse-(UUID().uuidString)")
            .appendingPathExtension("trace")

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctrace",
            "record",
            "--instrument", "Core Animation FPS",
            "--device", deviceID,
            "--attach", app.processName,
            "--time-limit", "(max(durationSeconds, 3))s",
            "--no-prompt",
            "--output", traceURL.path
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            if let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !message.isEmpty {
                onError(message)
            }
        }

        process.terminationHandler = { [weak self] process in
            errorPipe.fileHandleForReading.readabilityHandler = nil

            guard let self else { return }

            Task {
                defer {
                    try? FileManager.default.removeItem(at: traceURL)
                    self.fpsProcess = nil
                    self.fpsTraceURL = nil
                }

                guard FileManager.default.fileExists(atPath: traceURL.path) else {
                    if process.terminationStatus != 0 {
                        onError("Core Animation FPS recording failed to create a trace.")
                    }
                    return
                }

                do {
                    let fps = try await self.exportFPS(from: traceURL)
                    self.setLatestFPS(fps)
                    onResult(fps)
                } catch {
                    onError("Unable to read Core Animation FPS: (error.localizedDescription)")
                }
            }
        }

        do {
            try process.run()
        } catch {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            onError("Unable to start Core Animation FPS recording: (error.localizedDescription)")
            return false
        }

        fpsProcess = process
        fpsTraceURL = traceURL
        return true
    }

    func stopFPSRecording() {
        if let process = fpsProcess, process.isRunning {
            // xctrace flushes the trace when interrupted. terminate() is not
            // sufficient for a clean trace, so request a graceful interrupt.
            sendSIGINT(to: process)
        }

        fpsProcess = nil
        fpsTraceURL = nil
    }

    private func currentFPS() -> Double? {
        fpsLock.lock()
        defer { fpsLock.unlock() }
        return latestFPS
    }

    private func setLatestFPS(_ value: Double?) {
        fpsLock.lock()
        latestFPS = value
        fpsLock.unlock()
    }

    private func exportFPS(from traceURL: URL) async throws -> Double {
        let xpath = "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"core-animation-fps-estimate\"]"

        let result = try await runner.run(
            "/usr/bin/xcrun",
            arguments: [
                "xctrace",
                "export",
                "--input", traceURL.path,
                "--xpath", xpath
            ],
            timeout: 30
        )

        guard result.exitCode == 0 else {
            throw NSError(
                domain: "RNPulse.iOS",
                code: Int(result.exitCode),
                userInfo: [
                    NSLocalizedDescriptionKey: result.stderr.isEmpty
                        ? "xctrace could not export Core Animation FPS data."
                        : result.stderr
                ]
            )
        }

        guard let fps = CoreAnimationFPSParser.parse(result.stdout) else {
            throw NSError(
                domain: "RNPulse.iOS",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey: "Core Animation FPS trace contained no usable FPS samples."
                ]
            )
        }

        return fps
    }

    private func sendSIGINT(to process: Process) {
        kill(process.processIdentifier, SIGINT)
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
            "-vf", "scale=360:-2:flags=fast_bilinear,fps=20",
            "-c:v", "mjpeg",
            "-q:v", "7",
            "-f", "image2pipe",
            "pipe:1"
        ]
        ffmpegProcess.standardInput = ffmpegInput
        ffmpegProcess.standardOutput = ffmpegOutput
        ffmpegProcess.standardError = ffmpegError

        recordOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            do {
                try ffmpegInput.fileHandleForWriting.write(contentsOf: data)
            } catch {
                onError("Simulator mirror stream ended: (error.localizedDescription)")
            }
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

            onError("Unable to start fast simulator mirror: (error.localizedDescription)")
            return false
        }

        mirrorProcess = recordProcess
        mirrorDecoderProcess = ffmpegProcess
        mirrorInputPipe = ffmpegInput
        mirrorOutputPipe = ffmpegOutput
        mirrorErrorPipe = ffmpegError

        return true
    }

    func stopMirror() {
        mirrorOutputPipe?.fileHandleForReading.readabilityHandler = nil
        mirrorErrorPipe?.fileHandleForReading.readabilityHandler = nil

        try? mirrorInputPipe?.fileHandleForWriting.close()

        if let process = mirrorProcess, process.isRunning {
            process.terminate()
        }

        if let process = mirrorDecoderProcess, process.isRunning {
            process.terminate()
        }

        mirrorProcess = nil
        mirrorDecoderProcess = nil
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

private enum CoreAnimationFPSParser {
    static func parse(_ xml: String) -> Double? {
        let idPattern = "<(?:[A-Za-z0-9_-]+)[^>]*\\bid=\"([^\"]+)\"[^>]*\\bfmt=\"([^\"]*)\"[^>]*>"
        let rowPattern = "<row>(.*?)</row>"

        var valuesByID: [String: String] = [:]

        for match in matches(of: idPattern, in: xml) {
            guard match.count >= 2 else { continue }
            valuesByID[match[0]] = match[1]
        }

        var weightedFPS = 0.0
        var totalDuration = 0.0
        var unweightedValues: [Double] = []

        for rowMatch in matches(of: rowPattern, in: xml) {
            guard let row = rowMatch.first,
                  let fpsText = value(
                    forTag: "fps",
                    in: row,
                    valuesByID: valuesByID
                ),
                let fps = parseFPS(fpsText) else {
                continue
            }

            if let durationText = value(
                forTag: "duration",
                in: row,
                valuesByID: valuesByID
            ),
            let duration = parseSeconds(durationText),
            duration > 0 {
                weightedFPS += fps * duration
                totalDuration += duration
            } else {
                unweightedValues.append(fps)
            }
        }

        if totalDuration > 0 {
            return weightedFPS / totalDuration
        }

        guard !unweightedValues.isEmpty else { return nil }
        return unweightedValues.reduce(0, +) / Double(unweightedValues.count)
    }

    private static func value(
        forTag tag: String,
        in row: String,
        valuesByID: [String: String]
    ) -> String? {
        let escapedTag = NSRegularExpression.escapedPattern(for: tag)
        let pattern = "<\\(escapedTag)\\b([^>]*)>"

        guard let attributes = firstMatch(of: pattern, in: row)?.first else {
            return nil
        }

        if let fmt = attribute(named: "fmt", in: attributes) {
            return fmt
        }

        if let ref = attribute(named: "ref", in: attributes) {
            return valuesByID[ref]
        }

        return nil
    }

    private static func parseFPS(_ value: String) -> Double? {
        let cleaned = value.replacingOccurrences(of: ",", with: "")
        let pattern = "([0-9]+(?:\\.[0-9]+)?)\\s*FPS"

        if let match = firstMatch(of: pattern, in: cleaned)?.first,
           let fps = Double(match) {
            return fps
        }

        return Double(cleaned.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func parseSeconds(_ value: String) -> Double? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let match = firstMatch(
            of: "([0-9]+(?:\\.[0-9]+)?)\\s*(ms|s)",
            in: cleaned
        ),
        match.count >= 2,
        let number = Double(match[0]) else {
            return nil
        }

        return match[1] == "ms" ? number / 1000.0 : number
    }

    private static func attribute(named name: String, in attributes: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = "\\b\\(escapedName)=\"([^\"]*)\""
        return firstMatch(of: pattern, in: attributes)?.first
    }

    private static func firstMatch(
        of pattern: String,
        in string: String
    ) -> [String]? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ),
        let match = regex.firstMatch(
            in: string,
            range: NSRange(string.startIndex..., in: string)
        ) else {
            return nil
        }

        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: string) else {
                return nil
            }
            return String(string[range])
        }
    }

    private static func matches(
        of pattern: String,
        in string: String
    ) -> [[String]] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else {
            return []
        }

        let range = NSRange(string.startIndex..., in: string)

        return regex.matches(in: string, range: range).map { match in
            (1..<match.numberOfRanges).compactMap { index in
                guard let range = Range(match.range(at: index), in: string) else {
                    return nil
                }
                return String(string[range])
            }
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
