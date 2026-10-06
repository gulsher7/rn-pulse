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

    @Published var iosRunningApps: [IOSRunningApp] = []
    @Published var selectedIOSAppID: IOSRunningApp.ID?
    @Published var iosInstalledApps: [IOSInstalledApp] = []
    @Published var selectedIOSInstalledAppID: IOSInstalledApp.ID?
    @Published var livePreviewData: Data?
    @Published var isLaunchingIOSApp = false

    @Published var environment: EnvironmentSnapshot?
    @Published var isRefreshing = false
    @Published var isRunning = false
    @Published var statusMessage = "Select a device to get started."
    @Published var processOutput = ""
    @Published var lastExitCode: Int32?
    @Published var latestSnapshot: PerformanceSnapshot?
    @Published var performanceSnapshots: [PerformanceSnapshot] = []

    private let environmentService = EnvironmentService()
    private let androidService = AndroidDeviceService()
    private let iosService = IOSSimulatorService()
    private let iosPerformanceService = IOSPerformanceService()
    private let maestroService = MaestroService()
    private let performanceEngine = PerformanceEngine()

    private var monitoringTask: Task<Void, Never>?
    private var previewFallbackTask: Task<Void, Never>?
    private var currentStartupMS: Double?

    var selectedDevice: Device? {
        devices.first { $0.id == selectedDeviceID }
    }

    var selectedFlow: MaestroFlow? {
        flows.first { $0.id == selectedFlowID }
    }

    var selectedIOSApp: IOSRunningApp? {
        iosRunningApps.first { $0.id == selectedIOSAppID }
    }

    var selectedIOSInstalledApp: IOSInstalledApp? {
        iosInstalledApps.first { $0.id == selectedIOSInstalledAppID }
    }

    var canLaunchSelectedIOSApp: Bool {
        guard let device = selectedDevice,
              device.platform == .iOS,
              let app = selectedIOSInstalledApp else {
            return false
        }

        return (device.state == .booted || device.state == .shutdown)
            && !app.bundleID.isEmpty
    }

    var canStartMonitoring: Bool {
        guard let device = selectedDevice else { return false }

        if device.platform == .iOS {
            return device.state == .booted && selectedIOSApp != nil
        }

        return selectedFlow != nil
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

        if let device = selectedDevice {
            if device.platform == .iOS {
                if device.state == .booted {
                    startLivePreview()
                    await refreshIOSRunningApps()
                } else {
                    stopLivePreview()
                }

                await refreshIOSInstalledApps()
            } else {
                stopLivePreview()
            }
        }

        if devices.isEmpty {
            statusMessage = "No local devices found."
        } else {
            statusMessage = "Found \(devices.count) device(s)."
        }
    }

    func selectDevice(_ device: Device) {
        stopMonitoring()
        stopLivePreview()

        selectedDeviceID = device.id
        selectedIOSAppID = nil
        selectedIOSInstalledAppID = nil
        iosRunningApps = []
        iosInstalledApps = []
        livePreviewData = nil
        latestSnapshot = nil
        performanceSnapshots = []

        if device.platform == .iOS && device.state == .booted {
            startLivePreview()
            Task { await refreshIOSRunningApps() }
        } else if device.platform == .iOS {
            statusMessage = "Boot \(device.name) to mirror and monitor it."
        }
    }

    func refreshIOSInstalledApps() async {
        guard let device = selectedDevice, device.platform == .iOS else {
            iosInstalledApps = []
            selectedIOSInstalledAppID = nil
            return
        }

        do {
            let apps = try await iosService.listInstalledApps(deviceID: device.id)
            iosInstalledApps = apps

            if selectedIOSInstalledAppID == nil ||
                !apps.contains(where: { $0.id == selectedIOSInstalledAppID }) {
                selectedIOSInstalledAppID = apps.first?.id
            }
        } catch {
            iosInstalledApps = []
            selectedIOSInstalledAppID = nil
            statusMessage = "Unable to inspect installed apps: (error.localizedDescription)"
        }
    }

    func refreshIOSRunningApps() async {
        guard let device = selectedDevice, device.platform == .iOS else {
            iosRunningApps = []
            selectedIOSAppID = nil
            return
        }

        guard device.state == .booted else {
            iosRunningApps = []
            selectedIOSAppID = nil
            statusMessage = "Boot \(device.name) before selecting an app."
            return
        }

        do {
            let apps = try await iosPerformanceService.discoverRunningApps(deviceID: device.id)
            iosRunningApps = apps

            if selectedIOSAppID == nil || !apps.contains(where: { $0.id == selectedIOSAppID }) {
                selectedIOSAppID = apps.first?.id
            }

            if apps.isEmpty {
                statusMessage = "No running apps found. Launch your app from Xcode or Simulator, then refresh."
            } else {
                statusMessage = "Found \(apps.count) running app(s) on \(device.name)."
            }
        } catch {
            iosRunningApps = []
            selectedIOSAppID = nil
            statusMessage = "Unable to inspect running apps: \(error.localizedDescription)"
        }
    }

    func selectIOSInstalledApp(_ app: IOSInstalledApp) {
        selectedIOSInstalledAppID = app.id
        statusMessage = "Ready to launch (app.bundleID)."
    }

    func openSimulator() async throws {
        try await iosService.openSimulator()
    }

    func runSimulator(_ device: Device) {
        guard device.platform == .iOS else { return }

        Task { [weak self] in
            guard let self else { return }

            do {
                self.isLaunchingIOSApp = true
                self.statusMessage = "Booting \(device.name)…"

                try await self.iosService.bootAndOpen(deviceID: device.id)
                await self.refreshDevices()

                self.statusMessage = "\(device.name) is ready."
                self.isLaunchingIOSApp = false
            } catch {
                self.isLaunchingIOSApp = false
                self.statusMessage = "Unable to run \(device.name): \(error.localizedDescription)"
            }
        }
    }

    func runSelectedIOSApp() {
        guard let device = selectedDevice,
              device.platform == .iOS,
              let installedApp = selectedIOSInstalledApp else {
            return
        }

        stopMonitoring()
        isLaunchingIOSApp = true
        isRunning = false
        processOutput = ""
        lastExitCode = nil
        latestSnapshot = nil
        performanceSnapshots = []
        statusMessage = "Preparing \(installedApp.displayName)…"

        Task { [weak self] in
            guard let self else { return }

            do {
                if device.state != .booted {
                    statusMessage = "Booting \(device.name)…"
                    try await iosService.bootAndOpen(deviceID: device.id)
                    await refreshDevices()
                } else {
                    try await iosService.openSimulator()
                }

                guard let refreshedDevice = self.selectedDevice else {
                    throw NSError(
                        domain: "RNPulse.iOS",
                        code: 20,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Simulator is no longer available."
                        ]
                    )
                }

                statusMessage = "Launching \(installedApp.displayName)…"

                let launch = try await iosService.launchApp(
                    deviceID: refreshedDevice.id,
                    bundleID: installedApp.bundleID
                )

                selectedIOSInstalledAppID = installedApp.id
                await refreshIOSRunningApps()

                selectedIOSAppID = launch.app.id
                latestSnapshot = PerformanceSnapshot(
                    startupMS: launch.startupMS
                )

                statusMessage = launch.startupMS.map {
                    "Started \(installedApp.displayName) in \(String(format: "%.0f", $0)) ms. Monitoring…"
                } ?? "Started \(installedApp.displayName). Monitoring…"

                isLaunchingIOSApp = false
                startMonitoring(startupMS: launch.startupMS)
            } catch {
                isLaunchingIOSApp = false
                isRunning = false
                statusMessage = "Unable to launch \(installedApp.bundleID): \(error.localizedDescription)"
            }
        }
    }

    func selectIOSApp(_ app: IOSRunningApp) {
        stopMonitoring()
        selectedIOSAppID = app.id
        latestSnapshot = nil
        performanceSnapshots = []
        statusMessage = "Ready to monitor \(app.bundleID)."
    }

    func startLivePreview() {
        guard let device = selectedDevice,
              device.platform == .iOS,
              device.state == .booted else {
            return
        }

        stopLivePreview()
        livePreviewData = nil

        let started = iosPerformanceService.startMirror(
            deviceID: device.id,
            onFrame: { [weak self] frame in
                Task { @MainActor in
                    self?.livePreviewData = frame
                }
            },
            onError: { [weak self] message in
                Task { @MainActor in
                    // ffmpeg startup failures trigger the screenshot fallback.
                    if message.localizedCaseInsensitiveContains("ffmpeg was not found")
                       || message.localizedCaseInsensitiveContains("unable to start fast simulator mirror") {
                        self?.statusMessage = message
                    }
                }
            }
        )

        guard !started else {
            statusMessage = "Live simulator mirror connected."
            return
        }

        // Fallback for Macs without ffmpeg. This is intentionally slower but
        // keeps the basic preview functional.
        previewFallbackTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                if let screenshot = try? await self.iosPerformanceService.captureScreenshot(
                    deviceID: device.id
                ) {
                    self.livePreviewData = screenshot
                }

                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    func stopLivePreview() {
        previewFallbackTask?.cancel()
        previewFallbackTask = nil
        iosPerformanceService.stopMirror()
    }

    func startMonitoring(startupMS: Double? = nil) {
        guard let device = selectedDevice else {
            statusMessage = "Select a device first."
            return
        }

        guard device.platform == .iOS else {
            statusMessage = "Use Run Performance Test for Android."
            return
        }

        guard let app = selectedIOSApp else {
            statusMessage = "Launch an app on the simulator, then refresh running apps."
            return
        }

        stopMonitoring()

        isRunning = true
        processOutput = ""
        lastExitCode = nil
        latestSnapshot = nil
        performanceSnapshots = []
        statusMessage = "Monitoring \(app.bundleID) on \(device.name)…"

        startIOSFPSRecording(device: device, app: app)

        monitoringTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                do {
                    let captured = try await self.performanceEngine.capture(
                        device: device,
                        app: app
                    )
                    let snapshot = PerformanceSnapshot(
                        timestamp: captured.timestamp,
                        cpuPercent: captured.cpuPercent,
                        memoryMB: captured.memoryMB,
                        fps: captured.fps,
                        startupMS: self.currentStartupMS ?? captured.startupMS,
                        jsThreadPercent: captured.jsThreadPercent,
                        uiThreadPercent: captured.uiThreadPercent
                    )
                    self.latestSnapshot = snapshot
                    self.performanceSnapshots.append(snapshot)
                } catch {
                    self.statusMessage = error.localizedDescription
                    await self.refreshIOSRunningApps()
                    self.stopMonitoring()
                    break
                }

                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        iosPerformanceService.stopFPSRecording()

        if isRunning {
            isRunning = false
            statusMessage = "Monitoring stopped."
        }

        currentStartupMS = nil
    }

    private func startIOSFPSRecording(device: Device, app: IOSRunningApp) {
        guard isRunning || selectedIOSAppID == app.id else {
            return
        }

        let started = iosPerformanceService.startFPSRecording(
            deviceID: device.id,
            app: app,
            durationSeconds: 5,
            onResult: { [weak self] metrics in
                Task { @MainActor in
                    guard let self, self.isRunning else { return }

                    if let latest = self.latestSnapshot {
                        let updated = PerformanceSnapshot(
                            timestamp: .now,
                            cpuPercent: latest.cpuPercent,
                            memoryMB: latest.memoryMB,
                            fps: metrics.fps,
                            startupMS: latest.startupMS,
                            jsThreadPercent: metrics.jsPercent,
                            uiThreadPercent: metrics.uiPercent
                        )

                        self.latestSnapshot = updated

                        if let lastIndex = self.performanceSnapshots.indices.last {
                            self.performanceSnapshots[lastIndex] = updated
                        }
                    }

                    self.startIOSFPSRecording(device: device, app: app)
                }
            },
            onError: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.isRunning else { return }

                    self.statusMessage = message
                }
            }
        )

        if !started {
            statusMessage = "Unable to start native iOS performance recording."
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

        stopMonitoring()
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
