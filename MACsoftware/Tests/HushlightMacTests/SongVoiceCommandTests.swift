import Foundation
import XCTest
import BridgeCore
@testable import HushlightMac

private actor SongVoiceRunner: AutomationCodexRunning {
    let output: String
    var calls = 0
    init(_ output: String) { self.output = output }
    func decide(prompt: String, schema: Data) async throws -> Data { calls += 1; return Data(output.utf8) }
}
private struct NoOtherVoicePlanner: VoiceCommandPlanning {
    func propose(text: String) async throws -> VoiceCommandAction { .volumeRead }
}
final class SongVoiceCommandTests: XCTestCase {
    func testLiteralTitleArtistAndExplicitLiveAreBoundToSource() async throws {
        let runner = SongVoiceRunner(#"{"supported":true,"title":"晴天","artist":"周杰伦","version":"original"}"#)
        let planner = SongAwareVoiceCommandPlanner(runner: runner,other: NoOtherVoicePlanner())
        let result = try await planner.propose(text:"播放周杰伦的晴天")
        XCTAssertEqual(result,.songPlay(.init(title:"晴天",artist:"周杰伦")))
        do { _ = try await planner.propose(text:"播放夜曲"); XCTFail("Invented song accepted") } catch CodexAutomationError.invalidOutput {}
        let live = SongAwareVoiceCommandPlanner(runner:SongVoiceRunner(#"{"supported":true,"title":"晴天","artist":null,"version":"live"}"#),other:NoOtherVoicePlanner())
        let invalidVersion = try await live.propose(text:"播放晴天")
        guard case .unsupported = invalidVersion else { return XCTFail("Invented version accepted") }
        let played = try await live.propose(text:"播放晴天现场版")
        XCTAssertEqual(played,.songPlay(.init(title:"晴天",artist:nil,version:.live)))
    }
    func testNegatedCompoundAndNonImperativeRequestsCannotDirectPlay() async throws {
        let runner = SongVoiceRunner(#"{"supported":true,"title":"晴天","artist":null,"version":"original"}"#)
        let planner = SongAwareVoiceCommandPlanner(runner:runner,other:NoOtherVoicePlanner())
        for text in ["不要播放晴天","播放晴天然后发送微信","请播放晴天；然后播放夜曲","这句话说的是播放晴天","播放晴天吗？","播放晴天，删除桌面文件"] {
            guard case .unsupported = try await planner.propose(text:text) else { return XCTFail("No direct intent") }
        }
        let calls = await runner.calls; XCTAssertEqual(calls,0)
        let other = try await planner.propose(text:"读取当前音量"); XCTAssertEqual(other,.volumeRead)
    }
    func testMalformedOrInferredArgumentsAreRejected() async throws {
        for output in [#"{"supported":true,"title":"晴天","artist":"其他人","version":"original"}"#, #"{"supported":1,"title":"晴天","artist":null,"version":"original"}"#, #"{"supported":true,"title":"晴天","artist":null,"version":"remix"}"#, #"{"supported":true,"title":"晴天","artist":null,"version":"original","shell":"bad"}"#] {
            do {
                _ = try await SongAwareVoiceCommandPlanner(runner:SongVoiceRunner(output),other:NoOtherVoicePlanner()).propose(text:"播放晴天")
                XCTFail("Invalid model output accepted")
            } catch CodexAutomationError.invalidOutput {}
        }
    }
    func testPartialSongAndMissingArtistCannotAutoExecute() async throws {
        for (text,output) in [
            ("播放晴天", #"{"supported":true,"title":"晴","artist":null,"version":"original"}"#),
            ("播放晴天", #"{"supported":true,"title":"播放","artist":null,"version":"original"}"#),
            ("播放周杰伦的晴天", #"{"supported":true,"title":"晴天","artist":null,"version":"original"}"#),
            ("播放晴天和夜曲", #"{"supported":true,"title":"晴天","artist":null,"version":"original"}"#)
        ] {
            let result = try await SongAwareVoiceCommandPlanner(runner:SongVoiceRunner(output),other:NoOtherVoicePlanner()).propose(text:text)
            guard case .unsupported = result else { return XCTFail("Incomplete source coverage") }
        }
    }
    func testQuotedBoundariesAndVersionOutsideTitleAreRequired() async throws {
        for (text,output) in [
            ("播放周杰伦的晴天", #"{"supported":true,"title":"周杰伦的晴天","artist":null,"version":"original"}"#),
            ("播放《周杰伦的晴天》", #"{"supported":true,"title":"晴天","artist":"周杰伦","version":"original"}"#),
            ("播放Live Forever", #"{"supported":true,"title":"Live Forever","artist":null,"version":"live"}"#)
        ] {
            let result = try await SongAwareVoiceCommandPlanner(runner:SongVoiceRunner(output),other:NoOtherVoicePlanner()).propose(text:text)
            guard case .unsupported = result else { return XCTFail("Structure/version evidence lost") }
        }
        let literal = try await SongAwareVoiceCommandPlanner(runner:SongVoiceRunner(#"{"supported":true,"title":"Live Forever","artist":null,"version":"original"}"#),other:NoOtherVoicePlanner()).propose(text:"播放Live Forever")
        XCTAssertEqual(literal,.songPlay(.init(title:"Live Forever",artist:nil)))
        let quoted = try await SongAwareVoiceCommandPlanner(runner:SongVoiceRunner(#"{"supported":true,"title":"周杰伦的晴天","artist":null,"version":"original"}"#),other:NoOtherVoicePlanner()).propose(text:"播放《周杰伦的晴天》")
        XCTAssertEqual(quoted,.songPlay(.init(title:"周杰伦的晴天",artist:nil)))
    }
    func testUnquotedTitleCannotAbsorbVersionOrAnotherSong() async throws {
        for (text, output) in [
            ("播放晴天现场版", #"{"supported":true,"title":"晴天现场版","artist":null,"version":"original"}"#),
            ("播放周杰伦的晴天 Live", #"{"supported":true,"title":"晴天 Live","artist":"周杰伦","version":"original"}"#),
            ("播放晴天和夜曲", #"{"supported":true,"title":"晴天和夜曲","artist":null,"version":"original"}"#),
            ("播放周杰伦的晴天和夜曲", #"{"supported":true,"title":"晴天和夜曲","artist":"周杰伦","version":"original"}"#)
        ] {
            let result = try await SongAwareVoiceCommandPlanner(runner:SongVoiceRunner(output),other:NoOtherVoicePlanner()).propose(text:text)
            guard case .unsupported = result else { return XCTFail("Unquoted title absorbed a version or second song: \(text)") }
        }
        let quotedTitle = try await SongAwareVoiceCommandPlanner(
            runner:SongVoiceRunner(#"{"supported":true,"title":"晴天和夜曲","artist":null,"version":"original"}"#),
            other:NoOtherVoicePlanner()).propose(text:"播放《晴天和夜曲》")
        XCTAssertEqual(quotedTitle,.songPlay(.init(title:"晴天和夜曲",artist:nil)))
        let quotedVersionTitle = try await SongAwareVoiceCommandPlanner(
            runner:SongVoiceRunner(#"{"supported":true,"title":"晴天现场版","artist":"周杰伦","version":"original"}"#),
            other:NoOtherVoicePlanner()).propose(text:"播放周杰伦的《晴天现场版》")
        XCTAssertEqual(quotedVersionTitle,.songPlay(.init(title:"晴天现场版",artist:"周杰伦")))
    }
    func testRealCodexSongParsingOptInDoesNotExecuteMusic() async throws {
        guard ProcessInfo.processInfo.environment["WORKBENCH_SONG_ANALYSIS_SMOKE"] == "1" else { throw XCTSkip("Opt-in public-text Codex test") }
        let result = try await SongAwareVoiceCommandPlanner().propose(text:"播放周杰伦的晴天")
        XCTAssertEqual(result,.songPlay(.init(title:"晴天",artist:"周杰伦")))
    }
}

private actor SongVoiceBridge: BridgeService {
    var simulated = false
    var paused = false
    var calls = 0
    var ids: [String] = []
    func setSimulated(_ v:Bool) { simulated = v }
    func setPaused(_ v:Bool) async throws { paused = v }
    func snapshot() async throws -> BridgeSnapshot { .init(status:paused ? .paused:.localReady,permissions:[],recentActions:[]) }
    func workbenchState() async throws -> WorkbenchServiceState { .init(status:paused ? "paused":"localReady",supportedActions:["music.qq.searchPlay"],isSimulation:simulated) }
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }
    func searchAndPlayQQMusic(id:String,request:QQSongRequest,authorize:@escaping @Sendable () async -> Bool) async throws -> QQSongPlayResult {
        guard await authorize(),!paused else { throw QQSongSearchError.unauthorized }
        calls += 1;ids.append(id)
        return .init(requestID:id,status:"unknown",error:"result_unverifiable",playback:nil)
    }
}
extension SongVoiceCommandTests {
    func testExecutorForwardsStableIDAndUnknownAndBlocksSimulationOrPause() async throws {
        let bridge = SongVoiceBridge(),dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let executor = BridgeVoiceCommandExecutor(bridge:bridge,journalURL:dir.appendingPathComponent("voice.json"))
        let action = VoiceCommandAction.songPlay(.init(title:"Synthetic",artist:nil)),id = UUID()
        let value = await executor.execute(id:id,action:action,authorize:{true})
        XCTAssertEqual(value.outcome,.unknown)
        let ids = await bridge.ids;XCTAssertEqual(ids,[id.uuidString])
        await bridge.setSimulated(true)
        let simulated = await executor.execute(id:UUID(),action:action,authorize:{true})
        XCTAssertEqual(simulated.outcome,.denied)
        await bridge.setSimulated(false);try await bridge.setPaused(true)
        let paused = await executor.execute(id:UUID(),action:action,authorize:{true})
        XCTAssertEqual(paused.outcome,.denied)
        let calls = await bridge.calls;XCTAssertEqual(calls,1)
    }
}
