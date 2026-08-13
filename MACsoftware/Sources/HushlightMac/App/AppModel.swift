import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status: BridgeStatus = .notConfigured
    @Published private(set) var permissions: [PermissionStatus] = PermissionKind.allCases.map {
        PermissionStatus(kind: $0, state: .notRequested)
    }
    @Published private(set) var recentActions: [ActionRecord] = []
    @Published private(set) var lastErrorMessage: String?

    private let bridgeService: any BridgeService

    init(bridgeService: any BridgeService) {
        self.bridgeService = bridgeService
    }

    var isPaused: Bool {
        status == .paused
    }

    func refresh() async {
        do {
            let snapshot = try await bridgeService.snapshot()
            status = snapshot.status
            permissions = snapshot.permissions
            recentActions = snapshot.recentActions
            lastErrorMessage = nil
        } catch {
            status = .unavailable
            lastErrorMessage = error.localizedDescription
        }
    }

    func togglePause() async {
        let shouldPause = !isPaused

        do {
            try await bridgeService.setPaused(shouldPause)
            await refresh()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }
}
