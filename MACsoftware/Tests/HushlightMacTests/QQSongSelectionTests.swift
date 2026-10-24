import CoreGraphics
import XCTest
@testable import HushlightMac

final class QQSongSelectionTests: XCTestCase {
    private let selector = QQSongSelector()

    func testMatchesTitleAndArtistInDynamicRowGeometry() throws {
        let lines = [line("晴天", x: 0.25, y: 0.20),
                     line("周杰伦", x: 0.25, y: 0.23),
                     line("叶惠美", x: 0.65, y: 0.23)]
        let chosen = try selector.choose(QQSongRequest(title: "晴天", artist: "周杰伦"), lines: lines)
        XCTAssertEqual(chosen.title, "晴天")
        XCTAssertEqual(chosen.artist, "周杰伦")
        XCTAssertEqual(chosen.region, lines[0].rect)
    }

    func testOriginalExcludesLiveRemixAndPanoramicAudio() throws {
        let lines = row("晴天(Live)", "周杰伦", y: 0.20) +
            row("晴天(Remix)", "周杰伦", y: 0.31) +
            row("晴天 全景声", "周杰伦", y: 0.42) +
            row("晴天", "周杰伦", y: 0.53)
        let chosen = try selector.choose(QQSongRequest(title: "晴天", artist: "周杰伦"), lines: lines)
        XCTAssertEqual(chosen.region, lines[6].rect)
        let live = try selector.choose(QQSongRequest(title: "晴天", artist: "周杰伦", version: .live),
                                       lines: lines)
        XCTAssertEqual(live.region, lines[0].rect)
    }

    func testUniqueOriginalSingerTagResolvesMultipleOriginalRows() throws {
        let lines = row("晴天", "周杰伦", y: 0.20) +
            [line("原唱", x: 0.39, y: 0.31)] +
            row("晴天", "周杰伦", y: 0.31)
        let chosen = try selector.choose(QQSongRequest(title: "晴天", artist: "周杰伦"), lines: lines)
        XCTAssertEqual(chosen.region, lines[3].rect)
    }

    func testMultipleOriginalRowsWithoutUniqueTagAreAmbiguous() {
        let lines = row("晴天", "周杰伦", y: 0.20) + row("晴天", "周杰伦", y: 0.31)
        assertError(.ambiguous, request: QQSongRequest(title: "晴天", artist: "周杰伦"), lines: lines)
    }

    func testWrongArtistAndLowConfidenceAreNotEvidence() {
        assertError(.notFound, request: QQSongRequest(title: "晴天", artist: "周杰伦"),
                    lines: row("晴天", "其他歌手", y: 0.20))
        assertError(.notFound, request: QQSongRequest(title: "晴天", artist: "周杰伦"),
                    lines: [line("晴天", x: 0.25, y: 0.20, confidence: 0.69),
                            line("周杰伦", x: 0.25, y: 0.23)])
        assertError(.notFound, request: QQSongRequest(title: "晴天", artist: "周杰伦"),
                    lines: [line("晴天", x: 0.25, y: 0.20),
                            line("周杰伦", x: 0.25, y: 0.23, confidence: 0.69)])
    }

    func testSidebarAndHeaderTextWithoutAlignedArtistAreNotSongs() {
        let lines = [line("晴天", x: 0.03, y: 0.08),
                     line("周杰伦", x: 0.40, y: 0.11),
                     line("晴天", x: 0.25, y: 0.40),
                     line("搜索结果", x: 0.25, y: 0.44)]
        assertError(.notFound, request: QQSongRequest(title: "晴天", artist: "周杰伦"), lines: lines)
    }

    func testOnlyOneSongTitleWithoutArtistIsNotEnough() {
        assertError(.notFound, request: QQSongRequest(title: "晴天", artist: nil),
                    lines: [line("晴天", x: 0.25, y: 0.20)])
        assertError(.notFound, request: QQSongRequest(title: "晴天", artist: nil),
                    lines: [line("晴天", x: 0.25, y: 0.20),
                            line("搜索结果", x: 0.25, y: 0.23)])
    }

    private func row(_ title: String, _ artist: String, y: CGFloat) -> [WindowVisionLine] {
        [line(title, x: 0.25, y: y), line(artist, x: 0.25, y: y + 0.03)]
    }

    private func line(_ text: String, x: CGFloat, y: CGFloat,
                      confidence: Float = 0.9) -> WindowVisionLine {
        WindowVisionLine(text: text, confidence: confidence,
                         rect: CGRect(x: x, y: y, width: 0.12, height: 0.02), region: "selection")
    }

    private func assertError(_ expected: QQSongSearchError, request: QQSongRequest,
                             lines: [WindowVisionLine]) {
        do {
            _ = try selector.choose(request, lines: lines)
            XCTFail("Expected \(expected)")
        } catch let error as QQSongSearchError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
