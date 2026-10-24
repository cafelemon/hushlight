import AVFoundation
import Speech
import XCTest
@testable import HushlightMac

@MainActor
final class MacSpeechInputTests: XCTestCase {
    private let authorized = MacSpeechPermissions(microphone: .authorized, speech: .authorized)
    private let undecided = MacSpeechPermissions(microphone: .notDetermined, speech: .notDetermined)
    private let denied = MacSpeechPermissions(microphone: .denied, speech: .authorized)

    func testPassiveInitializationAndExplicitPermissionRequest() async {
        let backend = Fixture(permissions: undecided)
        backend.requestResult = authorized
        let model = MacSpeechInputModel(backend: backend)
        XCTAssertEqual(backend.requestCount, 0)
        XCTAssertEqual(backend.startCount, 0)
        XCTAssertTrue(model.permissionSummary.contains("需要"))

        await model.requestPermissions()
        XCTAssertEqual(backend.requestCount, 1)
        XCTAssertEqual(backend.startCount, 0)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.error)
        XCTAssertTrue(model.permissionSummary.contains("已授权"))
    }

    func testDuplicatePermissionRequestAndStopDiscardLateGrant() async {
        let backend = Fixture(permissions: undecided)
        backend.suspendPermission = true
        let model = MacSpeechInputModel(backend: backend)
        let pending = Task { await model.requestPermissions() }
        await backend.waitForPermissionRequest()
        await model.requestPermissions()
        XCTAssertEqual(backend.requestCount, 1)
        model.stop()
        await model.requestPermissions()
        await model.start()
        XCTAssertEqual(backend.requestCount, 1)
        XCTAssertEqual(backend.startCount, 0)
        backend.completePermission(authorized)
        await pending.value
        XCTAssertEqual(backend.startCount, 0)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(model.isRecording)
    }

    func testDeniedAndUnavailableFailBeforeAudioStart() async {
        let deniedBackend = Fixture(permissions: denied)
        let deniedModel = MacSpeechInputModel(backend: deniedBackend)
        await deniedModel.start()
        XCTAssertEqual(deniedBackend.requestCount, 0)
        XCTAssertEqual(deniedBackend.startCount, 0)
        XCTAssertNotNil(deniedModel.error)

        let undecidedBackend = Fixture(permissions: undecided)
        let undecidedModel = MacSpeechInputModel(backend: undecidedBackend)
        await undecidedModel.start()
        XCTAssertEqual(undecidedBackend.requestCount, 0)
        XCTAssertEqual(undecidedBackend.startCount, 0)
        XCTAssertTrue(undecidedModel.error?.contains("先点击授权") == true)

        let unavailableBackend = Fixture(permissions: authorized)
        unavailableBackend.onDeviceAvailable = false
        let unavailableModel = MacSpeechInputModel(backend: unavailableBackend)
        await unavailableModel.start()
        XCTAssertEqual(unavailableBackend.availabilityCount, 1)
        XCTAssertEqual(unavailableBackend.startCount, 0)
        XCTAssertTrue(unavailableModel.error?.contains("离线") == true)
    }

    func testLateCallbacksCannotOverwriteEditedTranscript() async {
        let backend = Fixture(permissions: authorized)
        let model = MacSpeechInputModel(backend: backend)
        await model.start()
        XCTAssertTrue(model.isRecording)
        backend.emit(.transcript("初始识别"))
        XCTAssertEqual(model.transcript, "初始识别")
        model.stop()
        model.transcript = "手动修订"
        backend.emit(.transcript("迟到识别"))
        backend.emit(.failure("迟到错误"))
        XCTAssertEqual(model.transcript, "手动修订")
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isRecording)
    }

    func testPauseDuringBackendStartStopsLateSessionAndPreventsRestart() async {
        let backend = Fixture(permissions: authorized)
        backend.suspendStart = true
        let model = MacSpeechInputModel(backend: backend)
        let pending = Task { await model.start() }
        await backend.waitForStart()
        model.setPaused(true)
        XCTAssertEqual(model.phase, .idle)
        await model.start()
        XCTAssertEqual(backend.startCount, 1)
        backend.completeStart()
        await pending.value
        XCTAssertFalse(model.isRecording)
        XCTAssertGreaterThanOrEqual(backend.stopCount, 1)

        model.setPaused(false)
        await model.start()
        XCTAssertTrue(model.isRecording)
        model.stop()
    }

    func testSelectedLocaleReachesBackend() async {
        let backend = Fixture(permissions: authorized)
        let model = MacSpeechInputModel(backend: backend)
        model.localeIdentifier = "fr-FR"
        await model.start()
        XCTAssertEqual(backend.lastLocale, "fr-FR")
        model.stop()
    }

    func testRecordingLimitStopsWithoutErasingTranscript() async {
        let backend = Fixture(permissions: authorized)
        let clock = ImmediateClock()
        let model = MacSpeechInputModel(backend: backend, recordingLimit: .seconds(60)) { duration in
            await clock.sleep(duration)
        }
        model.transcript = "保留的文字"
        await model.start()
        for _ in 0..<1000 where model.phase != .idle { await Task.yield() }
        XCTAssertEqual(clock.lastDuration, .seconds(60))
        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.transcript, "保留的文字")
        XCTAssertGreaterThanOrEqual(backend.stopCount, 1)
    }

    func testSynchronousFinishDuringStartLeavesModelIdle() async {
        let backend = Fixture(permissions: authorized)
        backend.eventDuringStart = .finished
        let model = MacSpeechInputModel(backend: backend)
        await model.start()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.isRecording)
    }

    func testOptionalNativePassiveSpeechProbe() throws {
        guard ProcessInfo.processInfo.environment["HUSHLIGHT_LIVE_SPEECH_STATUS"] == "1" else {
            throw XCTSkip("Set HUSHLIGHT_LIVE_SPEECH_STATUS=1 for a passive native capability probe")
        }
        let backend = AppleMacSpeechBackend()
        let grants = backend.permissionSnapshot()
        let capability = MacSpeechInputModel.supportedLocales.map { locale in
            "\(locale)=\(backend.onDeviceAvailability(localeIdentifier: locale))"
        }
        print("Speech passive status: microphone=\(grants.microphone.rawValue) speech=\(grants.speech.rawValue) \(capability.joined(separator: " "))")
    }
}

@MainActor
private final class ImmediateClock {
    var lastDuration: Duration?
    func sleep(_ duration: Duration) async {
        lastDuration = duration
    }
}

@MainActor
private final class Fixture: MacSpeechBackend {
    var permissions: MacSpeechPermissions
    var requestResult: MacSpeechPermissions?
    var onDeviceAvailable = true
    var suspendPermission = false
    var suspendStart = false
    var eventDuringStart: MacSpeechEvent?
    var requestCount = 0
    var availabilityCount = 0
    var startCount = 0
    var stopCount = 0
    var lastLocale: String?
    var onEvent: (@MainActor @Sendable (MacSpeechEvent) -> Void)?
    private var permissionContinuation: CheckedContinuation<MacSpeechPermissions, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var permissionStarted: CheckedContinuation<Void, Never>?
    private var startStarted: CheckedContinuation<Void, Never>?

    init(permissions: MacSpeechPermissions) { self.permissions = permissions }
    func permissionSnapshot() -> MacSpeechPermissions { permissions }
    func requestPermissions() async -> MacSpeechPermissions {
        requestCount += 1
        permissionStarted?.resume()
        permissionStarted = nil
        if suspendPermission {
            let value = await withCheckedContinuation { permissionContinuation = $0 }
            permissions = value
            return value
        }
        let value = requestResult ?? permissions
        permissions = value
        return value
    }
    func onDeviceAvailability(localeIdentifier: String) -> Bool {
        availabilityCount += 1
        return onDeviceAvailable
    }
    func start(localeIdentifier: String, onEvent: @escaping @MainActor @Sendable (MacSpeechEvent) -> Void) async throws {
        startCount += 1
        lastLocale = localeIdentifier
        self.onEvent = onEvent
        if let eventDuringStart { onEvent(eventDuringStart) }
        startStarted?.resume()
        startStarted = nil
        if suspendStart {
            await withCheckedContinuation { startContinuation = $0 }
            suspendStart = false
        }
    }
    func stop() { stopCount += 1 }
    func emit(_ event: MacSpeechEvent) { onEvent?(event) }
    func waitForPermissionRequest() async {
        if requestCount > 0 { return }
        await withCheckedContinuation { permissionStarted = $0 }
    }
    func waitForStart() async {
        if startCount > 0 { return }
        await withCheckedContinuation { startStarted = $0 }
    }
    func completePermission(_ value: MacSpeechPermissions) {
        permissionContinuation?.resume(returning: value)
        permissionContinuation = nil
    }
    func completeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }
}
