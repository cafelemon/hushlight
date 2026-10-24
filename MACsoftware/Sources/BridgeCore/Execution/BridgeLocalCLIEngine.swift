import Foundation

/// Line-based bridge-v1 compatibility facade.
public actor BridgeLocalCLIEngine {
    public static let maximumLineBytes = BridgeLocalRuntime.maximumMessageBytes
    private let runtime: BridgeLocalRuntime

    public init(simulate: Bool = false, allowVolumeControl: Bool = false, paused: Bool = false) async throws {
        runtime = try await BridgeLocalRuntime(simulate: simulate, allowVolumeControl: allowVolumeControl, paused: paused)
    }

    public func processLine(_ data: Data) async -> Data { await runtime.submit(data) }
    public func oversizedLineResponse() async -> Data { await runtime.oversizedLineResponse() }
}

public enum BridgeLocalCLIConfigurationError: Error {
    case conflictingModes
    case simulationUnavailable
}

#if DEBUG
actor SimulatedVolumeAdapter: CommandAdapter {
    nonisolated let supportedActions: Set<String> = [
        "system.volume.get", "system.volume.set", "system.volume.adjust"
    ]
    private var volume = 50.0

    func execute(_ command: BridgeCommand) async throws -> AdapterExecution {
        switch command.action {
        case "system.volume.get":
            break
        case "system.volume.set":
            guard case .object(let parameters) = command.parameters,
                  case .number(let value)? = parameters["value"] else {
                throw StableErrorCode.invalidSchema
            }
            volume = value
        case "system.volume.adjust":
            guard case .object(let parameters) = command.parameters,
                  case .number(let delta)? = parameters["delta"] else {
                throw StableErrorCode.invalidSchema
            }
            volume = min(100, max(0, volume + delta))
        default:
            throw StableErrorCode.capabilityDisabled
        }
        return .succeeded(summary: .object([
            "value": .number(volume),
            "simulation": .bool(true),
            "evidence": .string("simulation")
        ]))
    }
}
#endif
