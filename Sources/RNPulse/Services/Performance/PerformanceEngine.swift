import Foundation

enum PerformanceEngineError: LocalizedError {
    case unsupportedPlatform
    case missingAppId

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            "Performance collection is not implemented for this platform yet."
        case .missingAppId:
            "The selected Maestro flow does not define an appId."
        }
    }
}

actor PerformanceEngine {
    private let android = AndroidPerformanceService()

    func capture(device: Device, flow: MaestroFlow) async throws -> PerformanceSnapshot {
        switch device.platform {
        case .android:
            guard let appId = flow.appId, !appId.isEmpty else {
                throw PerformanceEngineError.missingAppId
            }
            return try await android.capture(packageId: appId, deviceId: device.id)

        case .iOS:
            throw PerformanceEngineError.unsupportedPlatform
        }
    }
}
