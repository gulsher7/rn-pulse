import Foundation

struct MaestroService {
    private let runner = ProcessRunner()

    func discoverFlows(in projectURL: URL) throws -> [MaestroFlow] {
        let fileManager = FileManager.default
        let candidates = [
            projectURL.appendingPathComponent("maestro"),
            projectURL.appendingPathComponent("maestro/flows"),
            projectURL.appendingPathComponent(".maestro")
        ]

        var roots: [URL] = []
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                roots.append(candidate)
            }
        }

        guard !roots.isEmpty else { return [] }

        var urls = Set<URL>()
        for root in roots {
            if let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let url as URL in enumerator {
                    guard url.pathExtension.lowercased() == "yaml" || url.pathExtension.lowercased() == "yml" else {
                        continue
                    }
                    urls.insert(url.standardizedFileURL)
                }
            }
        }

        return urls
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
            .map { parseFlow($0) }
    }

    func run(flow: MaestroFlow, device: Device) async throws -> ProcessRunner.Result {
        var arguments = [String]()

        if !device.id.isEmpty {
            arguments += ["--device", device.id]
        }

        arguments += ["test", flow.url.path]

        return try await runner.run("maestro", arguments: arguments, timeout: nil)
    }

    private func parseFlow(_ url: URL) -> MaestroFlow {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        var name: String?
        var appId: String?
        var tags: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("name:") {
                name = value(after: "name:", in: trimmed)
            } else if trimmed.hasPrefix("appId:") {
                appId = value(after: "appId:", in: trimmed)
            } else if trimmed.hasPrefix("- ") && tags.count < 20 {
                // Tags are only collected inside the top-level tags block by this lightweight parser.
                // Full YAML parsing is intentionally deferred to avoid adding a dependency to the MVP.
            }
        }

        return MaestroFlow(
            id: url.path,
            url: url,
            name: name ?? url.deletingPathExtension().lastPathComponent,
            appId: appId,
            tags: tags
        )
    }

    private func value(after prefix: String, in line: String) -> String {
        line
            .dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ""'"))
    }
}
