import Foundation

enum MetricKind: String, Codable, CaseIterable {
    case cpu
    case memory
    case fps
    case startup
}

enum MetricUnit: String, Codable {
    case percent
    case megabytes
    case framesPerSecond
    case milliseconds
}

struct MetricEvent: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let kind: MetricKind
    let value: Double
    let unit: MetricUnit
    let platform: DevicePlatform
    let deviceId: String
    let testStep: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        kind: MetricKind,
        value: Double,
        unit: MetricUnit,
        platform: DevicePlatform,
        deviceId: String,
        testStep: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.value = value
        self.unit = unit
        self.platform = platform
        self.deviceId = deviceId
        self.testStep = testStep
    }
}
