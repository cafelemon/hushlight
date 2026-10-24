import CoreAudio
import Foundation

/// A single default output snapshot. Device IDs are ephemeral Core Audio IDs, not names.
struct OutputVolumeSnapshot: Equatable, Sendable {
    let deviceID: AudioDeviceID
    let scalar: Float32
    let muted: Bool?

    init(deviceID: AudioDeviceID, scalar: Float32, muted: Bool?) {
        self.deviceID = deviceID
        self.scalar = scalar
        self.muted = muted
    }
}

enum VolumeBackendError: Error, Sendable {
    case noOutputDevice
    case unsupported
    case readFailed
    case writeFailed
}

/// Injected for deterministic fault tests; production uses only public Core Audio APIs.
protocol OutputVolumeBackend: Sendable {
    func snapshot() throws -> OutputVolumeSnapshot
    func setScalar(_ scalar: Float32, deviceID: AudioDeviceID) throws
}

actor SystemVolumeAdapter: CommandAdapter {
    nonisolated let supportedActions: Set<String>
    private let backend: any OutputVolumeBackend

    init(readOnly: Bool = false, backend: any OutputVolumeBackend = CoreAudioVolumeBackend()) {
        self.backend = backend
        supportedActions = readOnly
            ? ["system.volume.get"]
            : ["system.volume.get", "system.volume.set", "system.volume.adjust"]
    }

    func execute(_ command: BridgeCommand) async throws -> AdapterExecution {
        guard supportedActions.contains(command.action) else { throw StableErrorCode.capabilityDisabled }
        try ActionParameterValidator().validate(action: command.action, parameters: command.parameters)

        let before: OutputVolumeSnapshot
        do {
            before = try backend.snapshot()
            guard valid(before) else { throw VolumeBackendError.readFailed }
        } catch {
            return failure(error)
        }

        if command.action == "system.volume.get" {
            return .succeeded(summary: summary(before))
        }
        guard case let .object(parameters) = command.parameters else { throw StableErrorCode.invalidSchema }
        let target: Double
        switch command.action {
        case "system.volume.set":
            guard case let .number(value)? = parameters["value"] else { throw StableErrorCode.invalidSchema }
            target = value
        case "system.volume.adjust":
            guard case let .number(delta)? = parameters["delta"] else { throw StableErrorCode.invalidSchema }
            target = min(100, max(0, Double(before.scalar) * 100 + delta))
        default:
            throw StableErrorCode.capabilityDisabled
        }

        // No await between read/modify/write/read: concurrent adjustments serialize in this actor.
        do {
            try backend.setScalar(Float32(target / 100), deviceID: before.deviceID)
        } catch VolumeBackendError.unsupported {
            return AdapterExecution(status: .failed, stableError: .capabilityDisabled, summary: .emptyObject)
        } catch {
            // A setter error cannot prove that no hardware side effect occurred.
            return unknown()
        }
        do {
            let after = try backend.snapshot()
            guard valid(after), after.deviceID == before.deviceID,
                  abs(Double(after.scalar) * 100 - target) <= 1 else {
                return unknown()
            }
            return .succeeded(summary: summary(after))
        } catch {
            return unknown()
        }
    }

    private func valid(_ snapshot: OutputVolumeSnapshot) -> Bool {
        snapshot.deviceID != kAudioObjectUnknown && snapshot.scalar.isFinite && (0...1).contains(snapshot.scalar)
    }

    private func summary(_ snapshot: OutputVolumeSnapshot) -> JSONValue {
        .object([
            "device_id": .number(Double(snapshot.deviceID)),
            "value": .number(Double(snapshot.scalar) * 100),
            "muted": snapshot.muted.map(JSONValue.bool) ?? .null,
            "evidence": .string("core_audio_readback")
        ])
    }

    private func failure(_ error: any Error) -> AdapterExecution {
        let code: StableErrorCode
        if let volumeError = error as? VolumeBackendError, case .unsupported = volumeError {
            code = .capabilityDisabled
        } else {
            code = .internalError
        }
        return AdapterExecution(status: .failed, stableError: code, summary: .emptyObject)
    }

    private func unknown() -> AdapterExecution {
        AdapterExecution(status: .unknown, stableError: .resultUnverifiable, summary: .emptyObject)
    }
}

/// Intentionally supports only devices exposing a main output volume control.
/// It never switches devices, writes mute, or falls back to scripts/channel writes.
struct CoreAudioVolumeBackend: OutputVolumeBackend {
    init() {}

    func snapshot() throws -> OutputVolumeSnapshot {
        let device = try defaultOutput()
        var volumeAddress = address(kAudioDevicePropertyVolumeScalar)
        guard AudioObjectHasProperty(device, &volumeAddress) else { throw VolumeBackendError.unsupported }
        var scalar: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &scalar) == noErr,
              size == MemoryLayout<Float32>.size else { throw VolumeBackendError.readFailed }

        var muted: Bool?
        var muteAddress = address(kAudioDevicePropertyMute)
        if AudioObjectHasProperty(device, &muteAddress) {
            var value: UInt32 = 0
            var muteSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &muteSize, &value) == noErr,
               muteSize == MemoryLayout<UInt32>.size {
                muted = value != 0
            }
        }
        guard try defaultOutput() == device else { throw VolumeBackendError.readFailed }
        return OutputVolumeSnapshot(deviceID: device, scalar: scalar, muted: muted)
    }

    func setScalar(_ scalar: Float32, deviceID: AudioDeviceID) throws {
        guard scalar.isFinite, (0...1).contains(scalar), try defaultOutput() == deviceID else {
            throw VolumeBackendError.writeFailed
        }
        var volumeAddress = address(kAudioDevicePropertyVolumeScalar)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(deviceID, &volumeAddress),
              AudioObjectIsPropertySettable(deviceID, &volumeAddress, &settable) == noErr,
              settable.boolValue else { throw VolumeBackendError.unsupported }
        var value = scalar
        guard AudioObjectSetPropertyData(
            deviceID, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &value
        ) == noErr else { throw VolumeBackendError.writeFailed }
    }

    private func defaultOutput() throws -> AudioDeviceID {
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device) == noErr,
              size == MemoryLayout<AudioDeviceID>.size,
              device != kAudioObjectUnknown else { throw VolumeBackendError.noOutputDevice }
        return device
    }

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
