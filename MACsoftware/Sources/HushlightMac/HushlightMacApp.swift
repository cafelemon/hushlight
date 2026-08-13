import SwiftUI

@main
struct HushlightMacApp: App {
    @StateObject private var appModel = AppModel(
        bridgeService: PlaceholderBridgeService()
    )

    var body: some Scene {
        WindowGroup("小熙 Mac") {
            DashboardView(model: appModel)
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 860, height: 620)

        MenuBarExtra("小熙", systemImage: appModel.status.menuBarSymbol) {
            MenuBarView(model: appModel)
        }
    }
}
