import Foundation

struct AndroidDeviceService {
    private let runner = ProcessRunner()

    func discover() async throws -> [Device] {
        let result = try await runner.run("adb", arguments: ["devices", "-l"], timeout: 10)

        guard result.exitCode == 0 else {
            throw NSError(
                domain: "RNPulse.Android",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: result.stderr.isEmpty ? "ADB failed." : result.stderr]
            )
        }

        return parseDevices(result.stdout)
    }

    private func parseDevices(_ output: String) -> [Device] {
        output
            .split(separator: "\n")
            .dropFirst()
            .compactMap { line -> Device? in
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard let serial = parts.first else { return nil }

                let stateToken = parts.dropFirst().first.map(String.init) ?? "unknown"
                let state: DeviceState = stateToken == "device" ? .connected : .unavailable

                let attributes = parts.dropFirst(2).reduce(into: [String: String]()) { result, item in
                    let value = String(item)
                    let pair = value.split(separator: ":", maxSplits: 1).map(String.init)
                    if pair.count == 2 {
                        result[pair[0]] = pair[1]
                    }
                }

                let model = attributes["model"]?.replacingOccurrences(of: "_", with: " ") ?? String(serial)

                return Device(
                    id: String(serial),
                    name: model,
                    platform: .android,
                    osVersion: nil,
                    state: state,
                    modelIdentifier: attributes["device"]
                )
            }
    }
}
