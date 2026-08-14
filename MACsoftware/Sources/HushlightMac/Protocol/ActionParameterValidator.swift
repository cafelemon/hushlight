import Foundation

struct ActionParameterValidator: Sendable {
    func validate(action: String, parameters: JSONValue) throws {
        guard case let .object(object) = parameters else {
            throw StableErrorCode.invalidSchema
        }

        switch action {
        case "system.volume.get":
            try requireKeys(object, required: [], optional: [])
        case "system.volume.set":
            try requireKeys(object, required: ["value"], optional: [])
            try requireNumber(object, key: "value", range: 0...100)
        case "system.volume.adjust":
            try requireKeys(object, required: ["delta"], optional: [])
            try requireNumber(object, key: "delta", range: -100...100)
        case "timer.create":
            try requireKeys(object, required: ["timer_id", "fire_at", "label"], optional: [])
            try requireIdentifier(object, key: "timer_id")
            try requireDate(object, key: "fire_at")
            try requireString(object, key: "label", maximumLength: 256)
        case "timer.update":
            try requireKeys(object, required: ["timer_id"], optional: ["fire_at", "label"])
            try requireIdentifier(object, key: "timer_id")
            guard object["fire_at"] != nil || object["label"] != nil else {
                throw StableErrorCode.invalidSchema
            }
            if object["fire_at"] != nil { try requireDate(object, key: "fire_at") }
            if object["label"] != nil { try requireString(object, key: "label", maximumLength: 256) }
        case "timer.cancel":
            try requireKeys(object, required: ["timer_id"], optional: [])
            try requireIdentifier(object, key: "timer_id")
        case "reminder.create":
            try requireKeys(
                object,
                required: ["reminder_id", "title", "due_at"],
                optional: []
            )
            try requireIdentifier(object, key: "reminder_id")
            try requireString(object, key: "title", maximumLength: 256)
            try requireDate(object, key: "due_at")
        case "reminder.update":
            try requireKeys(
                object,
                required: ["reminder_id"],
                optional: ["title", "due_at"]
            )
            try requireIdentifier(object, key: "reminder_id")
            guard object["title"] != nil || object["due_at"] != nil else {
                throw StableErrorCode.invalidSchema
            }
            if object["title"] != nil { try requireString(object, key: "title", maximumLength: 256) }
            if object["due_at"] != nil { try requireDate(object, key: "due_at") }
        case "reminder.cancel":
            try requireKeys(object, required: ["reminder_id"], optional: [])
            try requireIdentifier(object, key: "reminder_id")
        case "content.open":
            try validateContentOpen(object)
        case "media.play", "media.pause", "media.previous", "media.next":
            try requireKeys(object, required: [], optional: ["provider"])
            if object["provider"] != nil {
                try requireEnum(object, key: "provider", values: ["system", "netease_music"])
            }
        case "music.search_and_play":
            try requireKeys(
                object,
                required: ["provider", "query"],
                optional: ["artist", "album"]
            )
            try requireEnum(object, key: "provider", values: ["netease_music"])
            try requireString(object, key: "query", maximumLength: 256)
            if object["artist"] != nil { try requireString(object, key: "artist", maximumLength: 256) }
            if object["album"] != nil { try requireString(object, key: "album", maximumLength: 256) }
        case "chat.draft":
            try requireKeys(
                object,
                required: ["provider", "content"],
                optional: ["target_name", "target_id"]
            )
            try requireEnum(object, key: "provider", values: ["wechat"])
            try requireString(object, key: "content", maximumLength: 2_000)
            let targetKeys = ["target_name", "target_id"].filter { object[$0] != nil }
            guard targetKeys.count == 1 else { throw StableErrorCode.invalidSchema }
            try requireString(object, key: targetKeys[0], maximumLength: 256)
        case "chat.send":
            try requireKeys(
                object,
                required: [
                    "provider",
                    "user_id",
                    "device_id",
                    "session_id",
                    "target_id",
                    "draft_sha256"
                ],
                optional: []
            )
            try requireEnum(object, key: "provider", values: ["wechat"])
            try requireIdentifier(object, key: "user_id")
            try requireIdentifier(object, key: "device_id")
            try requireIdentifier(object, key: "session_id")
            try requireString(object, key: "target_id", maximumLength: 256)
            try requireSHA256(object, key: "draft_sha256")
        default:
            throw StableErrorCode.capabilityDisabled
        }
    }

    private func validateContentOpen(_ object: [String: JSONValue]) throws {
        try requireKeys(object, required: [], optional: ["bundle_id", "url"])
        let targetKeys = ["bundle_id", "url"].filter { object[$0] != nil }
        guard targetKeys.count == 1 else { throw StableErrorCode.invalidSchema }

        if object["bundle_id"] != nil {
            let bundleID = try string(object, key: "bundle_id", maximumLength: 255)
            let parts = bundleID.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 2,
                  parts.allSatisfy({ part in
                      !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
                  }) else {
                throw StableErrorCode.invalidSchema
            }
            return
        }

        let rawURL = try string(object, key: "url", maximumLength: 2_048)
        guard let components = URLComponents(string: rawURL),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              !host.isEmpty,
              host != "localhost",
              !host.hasSuffix(".local"),
              !isIPAddress(host) else {
            throw StableErrorCode.invalidSchema
        }
    }

    private func requireKeys(
        _ object: [String: JSONValue],
        required: Set<String>,
        optional: Set<String>
    ) throws {
        let keys = Set(object.keys)
        guard required.isSubset(of: keys),
              keys.isSubset(of: required.union(optional)) else {
            throw StableErrorCode.invalidSchema
        }
    }

    private func requireIdentifier(_ object: [String: JSONValue], key: String) throws {
        let value = try string(object, key: key, maximumLength: 128)
        guard value.unicodeScalars.allSatisfy({ scalar in
            (65...90).contains(scalar.value)
                || (97...122).contains(scalar.value)
                || (48...57).contains(scalar.value)
                || [46, 95, 58, 45].contains(scalar.value)
        }) else {
            throw StableErrorCode.invalidSchema
        }
    }

    private func requireString(
        _ object: [String: JSONValue],
        key: String,
        maximumLength: Int
    ) throws {
        _ = try string(object, key: key, maximumLength: maximumLength)
    }

    private func string(
        _ object: [String: JSONValue],
        key: String,
        maximumLength: Int
    ) throws -> String {
        guard case let .string(value)? = object[key],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= maximumLength else {
            throw StableErrorCode.invalidSchema
        }
        return value
    }

    private func requireNumber(
        _ object: [String: JSONValue],
        key: String,
        range: ClosedRange<Double>
    ) throws {
        guard case let .number(value)? = object[key],
              value.isFinite,
              range.contains(value) else {
            throw StableErrorCode.invalidSchema
        }
    }

    private func requireDate(_ object: [String: JSONValue], key: String) throws {
        let value = try string(object, key: key, maximumLength: 64)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil { return }
        formatter.formatOptions = [.withInternetDateTime]
        guard formatter.date(from: value) != nil else {
            throw StableErrorCode.invalidSchema
        }
    }

    private func requireEnum(
        _ object: [String: JSONValue],
        key: String,
        values: Set<String>
    ) throws {
        let value = try string(object, key: key, maximumLength: 128)
        guard values.contains(value) else { throw StableErrorCode.invalidSchema }
    }

    private func requireSHA256(_ object: [String: JSONValue], key: String) throws {
        let value = try string(object, key: key, maximumLength: 64)
        guard value.count == 64,
              value == value.lowercased(),
              value.allSatisfy({ $0.isHexDigit }) else {
            throw StableErrorCode.invalidSchema
        }
    }

    private func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty,
                  part.allSatisfy(\.isNumber),
                  let value = Int(part) else { return false }
            return (0...255).contains(value)
        }
    }
}
