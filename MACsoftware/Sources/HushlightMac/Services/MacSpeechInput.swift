import AVFoundation
import Combine
import Foundation
import Speech

/// Only persisted system grants are read until the user presses a permission or record button.
struct MacSpeechPermissions: Equatable {
    let microphone: AVAuthorizationStatus
    let speech: SFSpeechRecognizerAuthorizationStatus

    var isAuthorized: Bool { microphone == .authorized && speech == .authorized }
    var isDenied: Bool {
        microphone == .denied || microphone == .restricted || speech == .denied || speech == .restricted
    }

    var summary: String {
        if isAuthorized { return "麦克风与语音识别已授权" }
        if isDenied { return "麦克风或语音识别未获授权，请在系统设置中检查" }
        return "录音前需要麦克风与语音识别授权"
    }
}

enum MacSpeechEvent: Equatable {
    case transcript(String)
    case finished
    case failure(String)
}

@MainActor
protocol MacSpeechBackend: AnyObject {
    func permissionSnapshot() -> MacSpeechPermissions
    func requestPermissions() async -> MacSpeechPermissions
    func onDeviceAvailability(localeIdentifier: String) -> Bool
    func start(localeIdentifier: String, onEvent: @escaping @MainActor @Sendable (MacSpeechEvent) -> Void) async throws
    func stop()
}

@MainActor
final class MacSpeechInputModel: ObservableObject {
    enum Phase: Equatable {
        case idle, requestingPermission, starting, recording
    }

    static let supportedLocales = ["zh-CN", "en-US", "fr-FR"]

    @Published var transcript = ""
    @Published var localeIdentifier = "zh-CN"
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var error: String?
    @Published private(set) var permissionSummary: String

    var isBusy: Bool { phase != .idle }
    var isRecording: Bool { phase == .recording }

    private let backend: any MacSpeechBackend
    private var generation: UInt64 = 0
    private var paused = false
    private var startInFlight = false
    private var permissionInFlight = false
    private var timeoutTask: Task<Void, Never>?
    private let recordingLimit: Duration
    private let sleep: @MainActor (Duration) async throws -> Void

    init(backend: any MacSpeechBackend = AppleMacSpeechBackend(),
         recordingLimit: Duration = .seconds(60),
         sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.backend = backend
        self.recordingLimit = recordingLimit
        self.sleep = sleep
        permissionSummary = backend.permissionSnapshot().summary
    }

    func requestPermissions() async {
        guard !paused, phase == .idle, !startInFlight, !permissionInFlight else { return }
        generation &+= 1
        let requestGeneration = generation
        phase = .requestingPermission
        permissionInFlight = true
        error = nil
        let permissions = await backend.requestPermissions()
        permissionInFlight = false
        guard requestGeneration == generation, !paused else { return }
        permissionSummary = permissions.summary
        phase = .idle
        if !permissions.isAuthorized { error = permissions.summary }
    }

    func start() async {
        guard !paused, phase == .idle, !startInFlight, !permissionInFlight else { return }
        generation &+= 1
        let recordingGeneration = generation
        error = nil
        guard Self.supportedLocales.contains(localeIdentifier) else {
            error = "不支持所选语言"
            return
        }
        let selectedLocale = localeIdentifier
        let permissions = backend.permissionSnapshot()
        permissionSummary = permissions.summary
        guard permissions.isAuthorized else {
            error = permissions.isDenied ? permissions.summary : "请先点击授权，再开始录音"
            phase = .idle
            return
        }
        // This check must happen before the backend creates or activates an audio engine.
        guard backend.onDeviceAvailability(localeIdentifier: selectedLocale) else {
            error = "此语言暂不支持本机离线语音识别"
            phase = .idle
            return
        }
        phase = .starting
        startInFlight = true
        do {
            try await backend.start(localeIdentifier: selectedLocale) { [weak self] event in
                self?.handle(event, generation: recordingGeneration)
            }
            startInFlight = false
            guard recordingGeneration == generation, !paused else {
                backend.stop()
                return
            }
            phase = .recording
            timeoutTask = Task { [weak self] in
                guard let self else { return }
                try? await self.sleep(self.recordingLimit)
                guard !Task.isCancelled else { return }
                self.finishAtLimit(generation: recordingGeneration)
            }
        } catch {
            startInFlight = false
            backend.stop()
            guard recordingGeneration == generation else { return }
            self.error = "录音启动失败，请检查麦克风设备与系统授权"
            phase = .idle
        }
    }

    func stop() {
        generation &+= 1
        timeoutTask?.cancel()
        timeoutTask = nil
        backend.stop()
        phase = .idle
    }

    func setPaused(_ value: Bool) {
        paused = value
        if value { stop() }
    }

    private func handle(_ event: MacSpeechEvent, generation eventGeneration: UInt64) {
        guard eventGeneration == generation, !paused else { return }
        switch event {
        case .transcript(let value):
            transcript = value
        case .finished:
            stop()
        case .failure:
            error = "语音识别中断，请重试"
            stop()
        }
    }

    private func finishAtLimit(generation limitGeneration: UInt64) {
        guard limitGeneration == generation, phase == .recording else { return }
        stop()
    }
}

@MainActor
final class AppleMacSpeechBackend: MacSpeechBackend {
    private var permissionEpoch: UInt64 = 0
    private var engine: AVAudioEngine?
    private var requestSink: LockedSpeechAudioRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    func permissionSnapshot() -> MacSpeechPermissions {
        MacSpeechPermissions(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio),
            speech: SFSpeechRecognizer.authorizationStatus()
        )
    }

    func requestPermissions() async -> MacSpeechPermissions {
        let requestEpoch = permissionEpoch
        var current = permissionSnapshot()
        if current.microphone == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        guard requestEpoch == permissionEpoch else { return permissionSnapshot() }
        current = permissionSnapshot()
        if current.speech == .notDetermined {
            _ = await requestSpeechAuthorization()
        }
        return permissionSnapshot()
    }

    func onDeviceAvailability(localeIdentifier: String) -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else { return false }
        return recognizer.supportsOnDeviceRecognition && recognizer.isAvailable
    }

    func start(localeIdentifier: String, onEvent: @escaping @MainActor @Sendable (MacSpeechEvent) -> Void) async throws {
        guard permissionSnapshot().isAuthorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.supportsOnDeviceRecognition,
              recognizer.isAvailable else {
            throw MacSpeechStartError.unavailable
        }
        stop()
        let audioEngine = AVAudioEngine()
        let speechRequest = SFSpeechAudioBufferRecognitionRequest()
        speechRequest.requiresOnDeviceRecognition = true
        speechRequest.shouldReportPartialResults = true
        let sink = LockedSpeechAudioRequest(speechRequest)
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MacSpeechStartError.invalidInputFormat
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: makeSpeechTap(sink: sink))
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        engine = audioEngine
        requestSink = sink
        recognitionTask = recognizer.recognitionTask(
            with: speechRequest,
            resultHandler: makeSpeechResultHandler(onEvent: onEvent)
        )
    }

    func stop() {
        permissionEpoch &+= 1
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        requestSink?.endAudio()
        recognitionTask?.cancel()
        engine = nil
        requestSink = nil
        recognitionTask = nil
    }
}

/// The audio tap runs on AVAudioEngine's render thread, outside the main actor.
/// Speech's request is never written after endAudio, even if a queued tap arrives late.
private final class LockedSpeechAudioRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let request: SFSpeechAudioBufferRecognitionRequest
    private var ended = false

    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { return }
        request.append(buffer)
    }

    func endAudio() {
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { return }
        ended = true
        request.endAudio()
    }
}

private func makeSpeechTap(sink: LockedSpeechAudioRequest) -> AVAudioNodeTapBlock {
    { buffer, _ in sink.append(buffer) }
}

private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { status in
            continuation.resume(returning: status)
        }
    }
}

private func makeSpeechResultHandler(
    onEvent: @escaping @MainActor @Sendable (MacSpeechEvent) -> Void
) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
    { result, error in
        let text = result?.bestTranscription.formattedString
        let isFinal = result?.isFinal == true
        let failed = error != nil
        Task { @MainActor in
            if let text { onEvent(.transcript(text)) }
            if failed { onEvent(.failure("recognition_interrupted")) }
            else if isFinal { onEvent(.finished) }
        }
    }
}

private enum MacSpeechStartError: LocalizedError {
    case unavailable, invalidInputFormat
    var errorDescription: String? {
        switch self {
        case .unavailable: "本机离线语音识别不可用或授权已失效"
        case .invalidInputFormat: "没有可用的麦克风输入格式"
        }
    }
}
