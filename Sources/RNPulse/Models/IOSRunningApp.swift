import Foundation

struct IOSRunningApp: Identifiable, Hashable, Codable {
    let id: String
    let bundleID: String
    let processID: Int
    let processName: String

    var displayName: String {
        processName.isEmpty ? bundleID : processName
    }
}
