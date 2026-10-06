import Foundation

enum EnvironmentStatus: String {
    case available
    case missing
    case unknown
}

struct EnvironmentCheck: Identifiable {
    let id: String
    let name: String
    let detail: String
    let status: EnvironmentStatus
    let command: String?
}

struct EnvironmentSnapshot {
    let checks: [EnvironmentCheck]

    var isReady: Bool {
        checks.allSatisfy { $0.status != .missing }
    }
}
