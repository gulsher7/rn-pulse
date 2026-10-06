import Foundation

@MainActor
final class EnvironmentService {
    private let runner = ProcessRunner()

    func check() async -> EnvironmentSnapshot {
        let checks = await withTaskGroup(of: EnvironmentCheck.self, returning: [EnvironmentCheck].self) { group in
            for item in [
                ("Xcode", "/usr/bin/xcodebuild", ["-version"]),
                ("xcrun", "/usr/bin/xcrun", ["--version"]),
                ("Android SDK / adb", "adb", ["version"]),
                ("Maestro", "maestro", ["--version"])
            ] {
                group.addTask {
                    await self.checkExecutable(
                        id: item.0,
                        name: item.0,
                        executable: item.1,
                        arguments: item.2
                    )
                }
            }

            var results: [EnvironmentCheck] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.name < $1.name }
        }

        return EnvironmentSnapshot(checks: checks)
    }

    private func checkExecutable(
        id: String,
        name: String,
        executable: String,
        arguments: [String]
    ) async -> EnvironmentCheck {
        do {
            let result = try await runner.run(executable, arguments: arguments, timeout: 8)
            if result.exitCode == 0 {
                let output = (result.stdout + result.stderr)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .newlines)
                    .first ?? "Available"

                return EnvironmentCheck(
                    id: id,
                    name: name,
                    detail: output,
                    status: .available,
                    command: executable
                )
            }

            return EnvironmentCheck(
                id: id,
                name: name,
                detail: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Command returned exit code \(result.exitCode)"
                    : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                status: .missing,
                command: executable
            )
        } catch {
            return EnvironmentCheck(
                id: id,
                name: name,
                detail: error.localizedDescription,
                status: .missing,
                command: executable
            )
        }
    }
}
