import Foundation

struct PerformanceSnapshot: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let cpuPercent: Double?
    let memoryMB: Double?
    let fps: Double?
    let startupMS: Double?
    let jsThreadPercent: Double?
    let uiThreadPercent: Double?

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        cpuPercent: Double? = nil,
        memoryMB: Double? = nil,
        fps: Double? = nil,
        startupMS: Double? = nil,
        jsThreadPercent: Double? = nil,
        uiThreadPercent: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.cpuPercent = cpuPercent
        self.memoryMB = memoryMB
        self.fps = fps
        self.startupMS = startupMS
        self.jsThreadPercent = jsThreadPercent
        self.uiThreadPercent = uiThreadPercent
    }
}

struct PerformanceRun: Codable {
    let startedAt: Date
    let endedAt: Date
    let device: Device
    let flowName: String
    let snapshots: [PerformanceSnapshot]
    let maestroExitCode: Int32
}
