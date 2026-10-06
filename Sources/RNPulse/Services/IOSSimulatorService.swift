import Foundation

struct IOSSimulatorService {
    private let runner = ProcessRunner()

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
                userInfo: [NSLocalizedDescriptionKey: result.stderr.isEmpty ? "simctl failed." : result.stderr]
            )
        }

        return try parseDevices(result.stdout)
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
}
