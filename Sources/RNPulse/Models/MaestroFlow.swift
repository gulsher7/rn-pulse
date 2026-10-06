import Foundation

struct MaestroFlow: Identifiable, Hashable {
    let id: String
    let url: URL
    let name: String
    let appId: String?
    let tags: [String]

    var path: String {
        url.path
    }
}
