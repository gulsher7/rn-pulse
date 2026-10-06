import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    @Published var projectURL: URL?
    @Published var devices: [Device] = []
    @Published var flows: [MaestroFlow] = []
    @Published var selectedDeviceID: Device.ID?
    @Published var selectedFlowID: MaestroFlow.ID?

    @Published var environment: EnvironmentSnapshot?
    @Published var isRefreshing = false
    @Published var isRunning = false
    @Published var statusMessage = "Select a project to get started."
    @Published var processOutput = ""
    @Published var lastExitCode: Int32?
    @Published var latestSnapshot: PerformanceSnapshot?
    @Published var performanceSnapshots: [PerformanceSnapshot] = []

    private let environmentService = EnvironmentService()
    private let androidService = AndroidDeviceService()
    private let iosService = IOSSimulatorService()
    private let maestroService = MaestroService()
    private let performanceEngine = PerformanceEngine()

    var selectedDevice: Device? {
        devices.first { $0.id == selectedDeviceID }
    }

    var selectedFlow: MaestroFlow? {
        flows.first { $0.id == selectedFlowID }
    }

    func refreshEnvironment() async {
        environment = await environmentService.check()
    }

    func refreshDevices() async {
        isRefreshing = true
        defer { isRefreshing = false }

        var discovered: [Device] = []

        do {
            discovered += try await androidService.discover()
        } catch {
            statusMessage = "Android discovery: \(error.localizedDescription)"
        }

        do {
            discovered += try await iosService.discover()
        } catch {
            statusMessage = "iOS discovery: \(error.localizedDescription)"
        }

        devices = discovered.sorted {
            if $0.platform != $1.platform {
                return $0.platform.rawValue < $1.platform.rawValue
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        if selectedDeviceID == nil || !devices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = devices.first?.id
        }

        if devices.isEmpty {
            statusMessage = "No local devices found."
        } else {
            statusMessage = "Found \(devices.count) device(s)."
        }
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Choose React Native Project"
        panel.message = "Select the root folder of your React Native project."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            projectURL = url
            loadFlows()
        }
    }

    func loadFlows() {
        guard let projectURL else {
            flows = []
            return
        }

        do {
            flows = try maestroService.discoverFlows(in: projectURL)
            selectedFlowID = flows.first?.id
            statusMessage = flows.isEmpty
                ? "No Maestro YAML flows found."
                : "Found \(flows.count) Maestro flow(s)."
        } catch {
            flows = []
            statusMessage = "Unable to discover Maestro flows: \(error.localizedDescription)"
        }
    }

    func runSelectedFlow() async {
        guard let device = selectedDevice else {
            statusMessage = "Select a device first."
            return
        }

        guard let flow = selectedFlow else {
            statusMessage = "Select a Maestro flow first."
            return
        }

        isRunning = true
        processOutput = ""
        lastExitCode = nil
        latestSnapshot = nil
        performanceSnapshots = []
        statusMessage = "Running \(flow.name) on \(device.name)…"

        let sampler = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                if let snapshot = try? await self.performanceEngine.capture(device: device, flow: flow) {
                    self.latestSnapshot = snapshot
                    self.performanceSnapshots.append(snapshot)
                }

                try? await Task.sleep(for: .milliseconds(750))
            }
        }

        defer {
            sampler.cancel()
            isRunning = false
        }

        do {
            let result = try await maestroService.run(flow: flow, device: device)
            processOutput = [result.stdout, result.stderr]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            lastExitCode = result.exitCode

            statusMessage = result.exitCode == 0
                ? "Test completed successfully."
                : "Test failed with exit code \(result.exitCode)."
        } catch {
            statusMessage = "Unable to run Maestro: \(error.localizedDescription)"
            processOutput += "\n\(error.localizedDescription)"
        }
    }
}
