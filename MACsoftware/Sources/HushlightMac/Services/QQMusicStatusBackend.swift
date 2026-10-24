import AppKit
import Foundation

/// Readiness metadata only. Playback is deliberately unknown until a separate, authorized integration exists.
struct QQMusicStatus: Codable, Equatable, Sendable {
    static let qqMusicBundleID = "com.tencent.QQMusicMac"

    let bundleID: String
    let installed: Bool
    let running: Bool
    let version: String?
    let checkedAt: Date
    let playbackStatus: String
    let controlsAvailable: Bool

    init(installed: Bool, running: Bool, version: String?, checkedAt: Date) {
        self.bundleID = Self.qqMusicBundleID
        self.installed = installed
        self.running = running
        self.version = version
        self.checkedAt = checkedAt
        self.playbackStatus = "unknown"
        self.controlsAvailable = false
    }

    private enum CodingKeys: String, CodingKey {
        case bundleID, installed, running, version, checkedAt, playbackStatus, controlsAvailable
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let bundleID = try values.decode(String.self, forKey: .bundleID)
        let playbackStatus = try values.decode(String.self, forKey: .playbackStatus)
        let controlsAvailable = try values.decode(Bool.self, forKey: .controlsAvailable)
        guard bundleID == Self.qqMusicBundleID, playbackStatus == "unknown", !controlsAvailable else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid QQ Music status constants"))
        }
        self.init(installed: try values.decode(Bool.self, forKey: .installed),
                  running: try values.decode(Bool.self, forKey: .running),
                  version: try values.decodeIfPresent(String.self, forKey: .version),
                  checkedAt: try values.decode(Date.self, forKey: .checkedAt))
    }
}

protocol QQMusicStatusProviding: Sendable {
    func status() async throws -> QQMusicStatus
}

/// A registered application is checked independently from the currently running process.
/// This permits `installed == false && running == true` when registration cannot be verified.
struct QQMusicAvailability: Sendable {
    let registeredBundleID: String?
    let registeredVersion: String?
    let runningBundleIDs: [String]
}

@MainActor
protocol QQMusicAvailabilityProviding: Sendable {
    func snapshot(bundleID: String) -> QQMusicAvailability
}

struct NativeQQMusicAvailabilityProvider: QQMusicAvailabilityProviding {
    @MainActor
    func snapshot(bundleID: String) -> QQMusicAvailability {
        let registration = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .flatMap(Bundle.init(url:))
        let runningIDs = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .compactMap(\.bundleIdentifier)
        return QQMusicAvailability(registeredBundleID: registration?.bundleIdentifier,
                                   registeredVersion: registration?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                                   runningBundleIDs: runningIDs)
    }
}

struct QQMusicStatusBackend: QQMusicStatusProviding {
    private let availability: any QQMusicAvailabilityProviding

    init(availability: any QQMusicAvailabilityProviding = NativeQQMusicAvailabilityProvider()) {
        self.availability = availability
    }

    func status() async throws -> QQMusicStatus {
        let snapshot = await availability.snapshot(bundleID: QQMusicStatus.qqMusicBundleID)
        let installed = snapshot.registeredBundleID == QQMusicStatus.qqMusicBundleID
        return QQMusicStatus(installed: installed,
                             running: snapshot.runningBundleIDs.contains(QQMusicStatus.qqMusicBundleID),
                             version: installed ? Self.validVersion(snapshot.registeredVersion) : nil,
                             checkedAt: Date())
    }

    private static func validVersion(_ raw: String?) -> String? {
        guard let version = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty, version.utf8.count <= 64,
              version.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return version
    }
}
