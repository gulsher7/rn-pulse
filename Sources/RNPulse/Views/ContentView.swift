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
                                    viewModel.selectedDeviceID = device.id
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

            Section("Maestro Flows") {
                if viewModel.flows.isEmpty {
                    Text(viewModel.projectURL == nil
                         ? "Choose a project first."
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
        .safeAreaInset(edge: .bottom) {
            EnvironmentSummary()
                .padding(10)
        }
    }
}

private struct DeviceRow: View {
    let device: Device
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: device.platform == .android ? "cpu" : "iphone")
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
                    .fill(device.state == .booted || device.state == .connected ? .green : .gray)
                    .frame(width: 7, height: 7)
            }
            .padding(7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
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
