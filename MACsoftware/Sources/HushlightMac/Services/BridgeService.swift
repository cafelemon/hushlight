import Foundation

protocol BridgeService: Sendable {
    func snapshot() async throws -> BridgeSnapshot
    func setPaused(_ paused: Bool) async throws
}

enum BridgeServiceError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Bridge 服务尚未配置"
        }
    }
}
