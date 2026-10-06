import Foundation

enum DevicePlatform: String, Codable, CaseIterable {
    case android
    case iOS

    var displayName: String {
        switch self {
        case .android: "Android"
        case .iOS: "iOS"
        }
    }
}

enum DeviceState: String, Codable {
    case booted
    case shutdown
    case connected
    case unavailable

    var displayName: String {
        switch self {
        case .booted: "Booted"
        case .shutdown: "Shutdown"
        case .connected: "Connected"
        case .unavailable: "Unavailable"
        }
    }
}

struct Device: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let platform: DevicePlatform
    let osVersion: String?
    let state: DeviceState
    let modelIdentifier: String?

    var subtitle: String {
        var values = [String]()
        if let osVersion, !osVersion.isEmpty {
            values.append(osVersion)
        }
        values.append(state.displayName)
        return values.joined(separator: " • ")
    }
}
