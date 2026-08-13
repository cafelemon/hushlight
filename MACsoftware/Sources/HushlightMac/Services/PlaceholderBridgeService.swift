import Foundation

actor PlaceholderBridgeService: BridgeService {
    private var isPaused = false

    func snapshot() async throws -> BridgeSnapshot {
        BridgeSnapshot(
            status: isPaused ? .paused : .notConfigured,
            permissions: PermissionKind.allCases.map {
                PermissionStatus(kind: $0, state: .notRequested)
            },
            recentActions: []
        )
    }

    func setPaused(_ paused: Bool) async throws {
        isPaused = paused
    }
}
