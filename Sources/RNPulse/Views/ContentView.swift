import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            DashboardView()
        }
        .task {
            await viewModel.refreshEnvironment()
            await viewModel.refreshDevices()
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        List {
            Section("Project") {
                Button {
                    viewModel.chooseProject()
                } label: {
                    Label(
                        viewModel.projectURL?.lastPathComponent ?? "Choose Project",
                        systemImage: "folder"
                    )
                }
                .buttonStyle(.plain)

                if let projectURL = viewModel.projectURL {
                    Text(projectURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }

            Section("Device") {
                if viewModel.devices.isEmpty {
                    Text("No devices found")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(DevicePlatform.allCases, id: \.self) { platform in
                        let platformDevices = viewModel.devices.filter { $0.platform == platform }

                        if !platformDevices.isEmpty {
                            Text(platform.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ForEach(platformDevices) { device in
                                DeviceRow(
                                    device: device,
                                    isSelected: viewModel.selectedDeviceID == device.id
                                ) {
                                    viewModel.selectDevice(device)
                                }
                            }
                        }
                    }
                }

                Button {
                    Task { await viewModel.refreshDevices() }
                } label: {
                    Label(
                        viewModel.isRefreshing ? "Refreshing…" : "Refresh Devices",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(viewModel.isRefreshing)
            }

            if viewModel.selectedDevice?.platform == .iOS {
                IOSInstalledAppsSection()
                IOSRunningAppsSection()
            }

            Section("Maestro Flows") {
                if viewModel.flows.isEmpty {
                    Text(viewModel.projectURL == nil
                         ? "Optional — choose a project to use Maestro."
                         : "No YAML flows found.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.flows) { flow in
                        Button {
                            viewModel.selectedFlowID = flow.id
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(flow.name)
                                    .foregroundStyle(.primary)
                                Text(flow.url.lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(7)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(viewModel.selectedFlowID == flow.id
                                      ? Color.accentColor.opacity(0.14)
                                      : Color.clear)
                        )
                    }
                }

                if viewModel.projectURL != nil {
                    Button {
                        viewModel.loadFlows()
                    } label: {
                        Label("Refresh Flows", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            if viewModel.selectedDevice?.platform == .iOS {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField(
                        "Search installed apps",
                        text: $viewModel.iosAppSearchText
                    )
                    .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .safeAreaInset(edge: .bottom) {
            EnvironmentSummary()
                .padding(10)
        }
    }
}

private struct IOSInstalledAppsSection: View {
    @EnvironmentObject private var viewModel: AppViewModel
    private var filteredApps: [IOSInstalledApp] {
        let query = viewModel.iosAppSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return Array(viewModel.iosInstalledApps.prefix(40))
        }

        return viewModel.iosInstalledApps
            .filter {
                $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.bundleID.localizedCaseInsensitiveContains(query)
            }
            .prefix(40)
            .map { $0 }
    }

    var body: some View {
        Section {
            if viewModel.iosInstalledApps.isEmpty {
                Text("No installed apps detected.")
                    .foregroundStyle(.secondary)

                Text(
                    viewModel.selectedDevice?.state == .booted
                        ? "Refresh to reload the simulator's installed apps."
                        : "Installed apps will be available even before you boot the simulator."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ForEach(filteredApps) { app in
                    Button {
                        viewModel.selectIOSInstalledApp(app)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.displayName)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text(app.bundleID)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(7)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(
                                viewModel.selectedIOSInstalledAppID == app.id
                                    ? Color.accentColor.opacity(0.14)
                                    : Color.clear
                            )
                    )
                }

                if viewModel.iosInstalledApps.count > filteredApps.count {
                    Text("Showing first \(filteredApps.count) apps")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if viewModel.selectedIOSInstalledApp != nil {
                Button {
                    viewModel.runSelectedIOSApp()
                } label: {
                    Label(
                        viewModel.isLaunchingIOSApp
                            ? "Launching…"
                            : "Run & Monitor",
                        systemImage: viewModel.isLaunchingIOSApp
                            ? "hourglass"
                            : "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canLaunchSelectedIOSApp || viewModel.isLaunchingIOSApp)
            }

            Button {
                Task { await viewModel.refreshIOSInstalledApps() }
            } label: {
                Label("Refresh Installed Apps", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isRefreshing || viewModel.isLaunchingIOSApp)
        } header: {
            HStack {
                Text("Installed iOS Apps")

                Spacer()

                Text("\(viewModel.iosInstalledApps.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct IOSRunningAppsSection: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        Section("Running iOS Apps") {
            if viewModel.selectedDevice?.state != .booted {
                Text("Boot the selected simulator first.")
                    .foregroundStyle(.secondary)
            } else if viewModel.iosRunningApps.isEmpty {
                Text("No running apps detected.")
                    .foregroundStyle(.secondary)

                Text("Use Run & Monitor above or launch from Xcode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.iosRunningApps) { app in
                    Button {
                        viewModel.selectIOSApp(app)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.displayName)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text(app.bundleID)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Text("PID \(app.processID)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(7)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(
                                viewModel.selectedIOSAppID == app.id
                                    ? Color.accentColor.opacity(0.14)
                                    : Color.clear
                            )
                    )
                }
            }

            Button {
                Task { await viewModel.refreshIOSRunningApps() }
            } label: {
                Label("Refresh Running Apps", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isRunning || viewModel.isLaunchingIOSApp)
        }
    }
}

private struct DeviceRow: View {
    let device: Device
    let isSelected: Bool
    let onSelect: () -> Void

    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(
                        systemName: device.platform == .android
                            ? "cpu"
                            : "iphone"
                    )
                    .frame(width: 22)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.name)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(device.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Circle()
                        .fill(
                            device.state == .booted
                                || device.state == .connected
                                ? .green
                                : .gray
                        )
                        .frame(width: 7, height: 7)
                }
                .padding(7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if device.platform == .iOS {
                Button {
                    if device.state == .shutdown {
                        viewModel.runSimulator(device)
                    } else {
                        Task {
                            try? await viewModel.openSimulator()
                        }
                    }
                } label: {
                    Image(
                        systemName: device.state == .shutdown
                            ? "play.fill"
                            : "macwindow"
                    )
                    .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(
                    device.state == .shutdown
                        ? "Boot and open Simulator"
                        : "Open Simulator"
                )
                .disabled(viewModel.isLaunchingIOSApp)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.14)
                        : Color.clear
                )
        )
    }
}

private struct EnvironmentSummary: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Environment")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(viewModel.environment?.isReady == true ? .green : .orange)
                    .frame(width: 8, height: 8)
            }

            if let environment = viewModel.environment {
                Text("\(environment.checks.filter { $0.status == .available }.count)/\(environment.checks.count) tools available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Checking local tools…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Refresh Environment") {
                Task { await viewModel.refreshEnvironment() }
            }
            .font(.caption)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
