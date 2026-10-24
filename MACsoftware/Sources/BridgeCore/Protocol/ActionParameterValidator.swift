import Foundation

struct ActionParameterValidator: Sendable {
    func validate(action: String, parameters: JSONValue, protocolVersion: String = "1.0") throws {
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
        case "reminder.complete":
            guard ["1.1", "1.2", "1.3", "1.4", "1.5", "1.6"].contains(protocolVersion) else { throw StableErrorCode.capabilityDisabled }
            try requireKeys(object, required: ["reminder_id", "is_completed"], optional: [])
            try requireIdentifier(object, key: "reminder_id")
            guard case .bool = object["is_completed"] else { throw StableErrorCode.invalidSchema }
        case "note.list":
            guard ["1.2", "1.3", "1.4", "1.5", "1.6"].contains(protocolVersion) else { throw StableErrorCode.capabilityDisabled }
            try requireKeys(object, required: [], optional: ["query"])
            if let query = object["query"] {
                guard case .string(let value) = query, value.count <= 256 else { throw StableErrorCode.invalidSchema }
            }
        case "note.read":
            guard ["1.2", "1.3", "1.4", "1.5", "1.6"].contains(protocolVersion) else { throw StableErrorCode.capabilityDisabled }
            try requireKeys(object, required: ["note_id"], optional: [])
            try requireString(object, key: "note_id", maximumLength: 2_048)
        case "note.create":
            guard ["1.2", "1.3", "1.4", "1.5", "1.6"].contains(protocolVersion) else { throw StableErrorCode.capabilityDisabled }
            try requireKeys(object, required: ["note_id", "title", "text"], optional: [])
            try requireIdentifier(object, key: "note_id")
            let title = try string(object, key: "title", maximumLength: 256)
            guard !title.contains("\n"), !title.contains("\r") else { throw StableErrorCode.invalidSchema }
            try requireString(object, key: "text", maximumLength: 8_000)
        case "note.append":
            guard ["1.2", "1.3", "1.4", "1.5", "1.6"].contains(protocolVersion) else { throw StableErrorCode.capabilityDisabled }
            try requireKeys(object, required: ["note_id", "text", "expected_revision"], optional: [])
            try requireString(object, key: "note_id", maximumLength: 2_048)
            try requireString(object, key: "text", maximumLength: 8_000)
            try requireSHA256(object, key: "expected_revision")
        case "weather.get":
            guard ["1.3", "1.4", "1.5", "1.6"].contains(protocolVersion) else { throw StableErrorCode.capabilityDisabled }
            try requireKeys(object, required: ["city_id"], optional: [])
            guard case .string(let cityID)? = object["city_id"], WeatherCities.byID(cityID) != nil else {
                throw StableErrorCode.invalidSchema
            }
        case "location.get":
            guard ["1.4", "1.5", "1.6"].contains(protocolVersion) else { throw StableErrorCode.capabilityDisabled }
            try requireKeys(object, required: [], optional: [])
        case "mail.search":
            guard ["1.5", "1.6"].contains(protocolVersion) else { throw StableErrorCode.capabilityDisabled }
            try requireKeys(object, required: [], optional: ["query", "unread_only"])
            if let query = object["query"] {
                guard case .string(let value) = query, value.count <= 256 else { throw StableErrorCode.invalidSchema }
            }
            if let flag = object["unread_only"] {
                guard case .bool = flag else { throw StableErrorCode.invalidSchema }
            }
        case "mail.read":
            guard ["1.5", "1.6"].contains(protocolVersion) else { throw StableErrorCode.capabilityDisabled }
            try requireKeys(object, required: ["message_id"], optional: [])
            try requireString(object, key: "message_id", maximumLength: 256)
        case "mail.draft.create":
            guard protocolVersion == "1.6" else { throw StableErrorCode.capabilityDisabled }
            try requireKeys(object, required: ["draft_id", "sender", "to", "subject", "text"], optional: ["cc", "bcc"])
            try requireIdentifier(object, key: "draft_id")
            func addresses(_ key: String) throws -> [String] {
                guard let value = object[key] else { return [] }
                guard case .array(let list) = value, list.count <= 20 else { throw StableErrorCode.invalidSchema }
                return try list.map { guard case .string(let s) = $0 else { throw StableErrorCode.invalidSchema }; return s }
            }
            guard case .string(let subject)? = object["subject"], case .string(let text)? = object["text"] else { throw StableErrorCode.invalidSchema }
            let input = MailDraftInput(sender: try string(object, key: "sender", maximumLength: 254), to: try addresses("to"), cc: try addresses("cc"), bcc: try addresses("bcc"), subject: subject, text: text)
            try input.validate()
        case "mail.draft.read", "mail.draft.status", "mail.send.request":
            guard protocolVersion == "1.6" else { throw StableErrorCode.capabilityDisabled }
            try requireKeys(object, required: action == "mail.send.request" ? ["draft_id", "expected_revision"] : ["draft_id"], optional: [])
            try requireIdentifier(object, key: "draft_id")
            if action == "mail.send.request" { try requireSHA256(object, key: "expected_revision") }
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
