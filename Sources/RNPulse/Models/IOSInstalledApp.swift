import Foundation

struct IOSInstalledApp: Identifiable, Hashable, Codable {
    let id: String
    let bundleID: String
    let displayName: String
    let executableName: String?

    var subtitle: String {
        bundleID
    }
}
