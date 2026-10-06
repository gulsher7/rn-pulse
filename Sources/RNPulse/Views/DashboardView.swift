import AppKit
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()

            Divider()

            HStack(spacing: 0) {
                LivePreviewView()
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

            if viewModel.selectedDevice?.platform == .iOS {
                Button {
                    if viewModel.isRunning {
                        viewModel.stopMonitoring()
                    } else {
                        viewModel.startMonitoring()
                    }
                } label: {
                    Label(
                        viewModel.isRunning ? "Stop Monitoring" : "Start Monitoring",
                        systemImage: viewModel.isRunning ? "stop.fill" : "waveform.path.ecg"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.isRunning && !viewModel.canStartMonitoring)
            } else {
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
        }
        .padding(16)
    }
}

private struct LivePreviewView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 14) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 26)
                    .fill(Color.black)
                    .frame(width: 300, height: 580)
                    .shadow(radius: 18)

                if let data = viewModel.livePreviewData,
                   let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 300, height: 580)
                        .clipShape(RoundedRectangle(cornerRadius: 26))
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: viewModel.selectedDevice?.platform == .android ? "cpu" : "iphone")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.7))

                        Text(viewModel.selectedDevice?.name ?? "No device selected")
                            .font(.headline)
                            .foregroundStyle(.white)

                        Text(previewMessage)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                            .frame(width: 220)
                    }
                    .padding(24)
                }

                if viewModel.isRunning {
                    VStack {
                        HStack {
                            Spacer()

                            Label("LIVE", systemImage: "circle.fill")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.65), in: Capsule())
                        }

                        Spacer()
                    }
                    .padding(14)
                    .frame(width: 300, height: 580)
                }
            }

            if let app = viewModel.selectedIOSApp {
                Label(app.bundleID, systemImage: "app")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let flow = viewModel.selectedFlow {
                Label(flow.name, systemImage: "flowchart")
                    .font(.callout)
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

    private var previewMessage: String {
        guard let device = viewModel.selectedDevice else {
            return "Select a device."
        }

        if device.platform == .iOS {
            if device.state != .booted {
                return "Boot this simulator first."
            }

            if viewModel.selectedIOSApp == nil {
                return "Launch your app from Xcode or Simulator, then refresh running apps."
            }

            return "Start monitoring to mirror the running simulator."
        }

        return "Android live preview will be connected through the native device bridge."
    }
}

private struct PerformancePanel: View {
    @EnvironmentObject private var viewModel: AppViewModel

    private var snapshot: PerformanceSnapshot? {
        viewModel.latestSnapshot
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Performance")
                        .font(.title3.bold())

                    Spacer()

                    if !viewModel.performanceSnapshots.isEmpty {
                        Text("\(viewModel.performanceSnapshots.count) samples")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LazyVGrid(
                    columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ],
                    spacing: 10
                ) {
                    MetricCard(
                        title: "CPU",
                        value: formatted(snapshot?.cpuPercent),
                        unit: "%",
                        icon: "cpu"
                    )
                    MetricCard(
                        title: "Memory",
                        value: formatted(snapshot?.memoryMB),
                        unit: "MB",
                        icon: "memorychip"
                    )
                    MetricCard(
                        title: "FPS",
                        value: formatted(snapshot?.fps),
                        unit: "",
                        icon: "speedometer"
                    )
                    MetricCard(
                        title: "Startup",
                        value: formatted(snapshot?.startupMS),
                        unit: "ms",
                        icon: "timer"
                    )
                }

                if viewModel.selectedDevice?.platform == .iOS {
                    InfoBanner(
                        title: "iOS Simulator monitoring",
                        message: "CPU and memory are collected directly from the running simulator process. FPS and startup are shown only when a reliable native measurement is available; RN Pulse does not estimate them."
                    )
                }

                if let app = viewModel.selectedIOSApp {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Monitored App")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(app.bundleID)
                                .font(.callout.bold())

                            Text("PID \(app.processID) • \(app.processName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Test Flow")
                            .font(.headline)

                        if let flow = viewModel.selectedFlow {
                            FlowSummary(flow: flow)
                        } else {
                            Text("Maestro is optional. For iOS, launch the app normally and select it from Running Apps.")
                                .foregroundStyle(.secondary)
                        }
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

    private func formatted(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f", value)
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

private struct InfoBanner: View {
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.bold())
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
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
