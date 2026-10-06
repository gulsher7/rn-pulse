import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()

            Divider()

            HStack(spacing: 0) {
                LivePreviewPlaceholder()
                    .frame(minWidth: 480, maxWidth: .infinity)

                Divider()

                PerformancePanel()
                    .frame(width: 430)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct HeaderView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("RN Pulse")
                    .font(.title2.bold())

                Text(viewModel.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let device = viewModel.selectedDevice {
                Label(device.name, systemImage: device.platform == .android ? "cpu" : "iphone")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await viewModel.runSelectedFlow() }
            } label: {
                Label(
                    viewModel.isRunning ? "Running…" : "Run Performance Test",
                    systemImage: viewModel.isRunning ? "stopwatch" : "play.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isRunning || viewModel.selectedDevice == nil || viewModel.selectedFlow == nil)
        }
        .padding(16)
    }
}

private struct LivePreviewPlaceholder: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 26)
                    .fill(Color.black)
                    .frame(width: 300, height: 580)
                    .shadow(radius: 18)

                VStack(spacing: 12) {
                    Image(systemName: viewModel.selectedDevice?.platform == .android ? "cpu" : "iphone")
                        .font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.7))

                    Text(viewModel.selectedDevice?.name ?? "No device selected")
                        .font(.headline)
                        .foregroundStyle(.white)

                    Text("Live device preview")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))

                    Text("Embedded streaming will be added after the core runner is stable.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                        .frame(width: 220)
                }
                .padding(24)
            }

            if let flow = viewModel.selectedFlow {
                Label(flow.name, systemImage: "flowchart")
                    .font(.callout)
            } else {
                Text("Select a Maestro flow")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .controlBackgroundColor)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

private struct PerformancePanel: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Performance")
                    .font(.title3.bold())

                LazyVGrid(
                    columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ],
                    spacing: 10
                ) {
                    MetricCard(title: "CPU", value: "—", unit: "%", icon: "cpu")
                    MetricCard(title: "Memory", value: "—", unit: "MB", icon: "memorychip")
                    MetricCard(title: "FPS", value: "—", unit: "", icon: "speedometer")
                    MetricCard(title: "Startup", value: "—", unit: "ms", icon: "timer")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Test Flow")
                        .font(.headline)

                    if let flow = viewModel.selectedFlow {
                        FlowSummary(flow: flow)
                    } else {
                        Text("Select a Maestro flow from the sidebar.")
                            .foregroundStyle(.secondary)
                    }
                }

                if !viewModel.processOutput.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Runner Output")
                            .font(.headline)

                        ScrollView {
                            Text(viewModel.processOutput)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(10)
                        }
                        .frame(minHeight: 140, maxHeight: 260)
                        .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                if let code = viewModel.lastExitCode {
                    HStack {
                        Image(systemName: code == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(code == 0 ? .green : .red)

                        Text(code == 0 ? "Test passed" : "Test failed (exit code \(code))")
                            .font(.callout.bold())
                    }
                }
            }
            .padding(18)
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let unit: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct FlowSummary: View {
    let flow: MaestroFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(flow.name)
                .font(.callout.bold())

            Text(flow.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let appId = flow.appId {
                Label(appId, systemImage: "app")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
