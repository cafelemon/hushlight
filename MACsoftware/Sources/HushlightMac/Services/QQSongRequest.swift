import Foundation
import CoreGraphics

enum QQSongVersion: String, Codable, Sendable { case original, live }

struct QQSongRequest: Codable, Equatable, Sendable {
    let title: String
    let artist: String?
    var version: QQSongVersion = .original

    func validate() throws {
        for value in [title, artist].compactMap({ $0 }) {
            guard !value.isEmpty, value.count <= 120,
                  value == value.trimmingCharacters(in: .whitespacesAndNewlines),
                  value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw QQSongSearchError.invalidInput
            }
        }
    }
    var query: String { [title, artist].compactMap { $0 }.joined(separator: " ") }
}

struct QQSongCandidate: Sendable {
    let title: String
    let artist: String
    let region: CGRect
}

enum QQSongSearchError: Error, Equatable {
    case invalidInput, permissionRequired, notRunning, unavailableWindow
    case notFound, ambiguous, unauthorized, unknownOutcome, busy, duplicateConflict
}

protocol QQSongSelecting: Sendable {
    func choose(_ request: QQSongRequest, lines: [WindowVisionLine]) throws -> QQSongCandidate
}

protocol QQSongSearchPlaying: Sendable {
    /// beforePlay is durable admission immediately before each native playback attempt.
    /// It must not be called for read-only search or after an unknown outcome.
    func play(_ request: QQSongRequest,
              authorize: @escaping @Sendable () async -> Bool,
              beforePlay: @escaping @Sendable () async throws -> Void) async throws -> QQMusicPlayback
}
