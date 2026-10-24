import SwiftUI
import WorkbenchKit

@main
struct HushlightMacApp: App {
    @StateObject private var appModel: AppModel
    @StateObject private var automation: AutomationCenterModel
    @StateObject private var speechInput: MacSpeechInputModel
    @StateObject private var windowVision = WindowVisionModel()
    @StateObject private var voiceCommands: VoiceCommandModel
    private let host: WorkbenchHost?

    init() {
        let bridge = LocalBridgeService()
        let speech = MacSpeechInputModel()
        _speechInput = StateObject(wrappedValue: speech)
        let commands = VoiceCommandModel(executor: BridgeVoiceCommandExecutor(bridge: bridge), inputProvider: { speech.transcript })
        commands.bindInput(speech.$transcript)
        _voiceCommands = StateObject(wrappedValue: commands)
        let broker = AutomationAgentBroker()
        let workbenchHost = try? WorkbenchHost(bridge: bridge, agentBroker: broker)
        let engine = workbenchHost == nil ? nil : try? AutomationEngine(storageURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Hushlight/Bridge/automation.json"), input: BridgeAutomationInput(bridge: bridge), analyzer: AutomationAgentRouter(codex: CodexAutomationAnalyzer(), broker: broker), effectDriver: BridgeAutomationEffects(bridge: bridge), connectionAuthorization: { clientID in await workbenchHost?.workerAuthorized(clientID: clientID) ?? false })
        let automationModel = AutomationCenterModel(bridge: bridge, engine: engine, host: workbenchHost)
        _automation = StateObject(wrappedValue: automationModel)
        let model = AppModel(bridgeService: bridge)
        _appModel = StateObject(wrappedValue: model)
        host = workbenchHost
        Task {
            if let workbenchHost {
                do {
                    try await workbenchHost.start()
                    if let engine { await bridge.attachAutomation(engine) }
                    automationModel.start()
                } catch { /* No scheduler if the unique host could not start. */ }
            }
            await model.refresh()
        }
    }

    var body: some Scene {
        WindowGroup("Orbit 智轨") {
            DashboardView(model: appModel, host: host, automation: automation, speechInput: speechInput, windowVision: windowVision, voiceCommands: voiceCommands)
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 860, height: 620)

        MenuBarExtra("Orbit 智轨", systemImage: appModel.status.menuBarSymbol) {
            MenuBarView(model: appModel)
        }
    }
}
