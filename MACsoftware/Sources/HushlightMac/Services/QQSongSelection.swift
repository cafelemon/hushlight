import CoreGraphics
import Foundation

/// Selects from on-device OCR only. The returned rectangle belongs to the title line,
/// and no other search-result text escapes this selector.
struct QQSongSelector: QQSongSelecting {
    private let minimumConfidence: Float

    init(minimumConfidence: Float = 0.70) {
        self.minimumConfidence = minimumConfidence
    }

    func choose(_ request: QQSongRequest, lines: [WindowVisionLine]) throws -> QQSongCandidate {
        try request.validate()
        let title = Self.normalized(request.title)
        let artist = request.artist.map(Self.normalized)
        let usable = lines.enumerated().filter { _, line in
            line.confidence.isFinite && line.confidence >= minimumConfidence &&
            Self.valid(line.rect) && !Self.normalized(line.text).isEmpty
        }
        var candidates: [(song: QQSongCandidate, originalTag: Bool)] = []

        for (titleIndex, titleLine) in usable {
            guard let parsed = Self.parseTitle(titleLine.text, expected: title) else { continue }
            let sameRow = usable.filter { index, line in
                index != titleIndex && Self.isSameRow(line.rect, titleLine.rect) &&
                line.rect.minX >= titleLine.rect.minX &&
                line.rect.minX - titleLine.rect.maxX <= max(0.08, titleLine.rect.height * 4)
            }
            let nearbyText = sameRow.map { Self.normalized($0.element.text) }
            let versionText = ([parsed.annotation] + nearbyText.filter(Self.isKnownVersionAnnotation))
                .joined(separator: " ")
            let variant = Self.variant(in: versionText)
            switch request.version {
            case .original:
                guard !variant.live && !variant.alternative else { continue }
            case .live:
                guard variant.live && !variant.alternative else { continue }
            }

            let artistLines = usable.compactMap { index, line -> (WindowVisionLine, CGFloat)? in
                guard index != titleIndex,
                      Self.isArtistBelow(line.rect, title: titleLine.rect),
                      Self.normalized(line.text) != title,
                      !Self.isKnownVersionAnnotation(Self.normalized(line.text)) else { return nil }
                let normalizedArtist = Self.normalized(line.text)
                guard !Self.isInterfaceLabel(normalizedArtist),
                      artist == nil || normalizedArtist == artist else { return nil }
                return (line, line.rect.minY - titleLine.rect.maxY)
            }.sorted { $0.1 < $1.1 }
            guard let closest = artistLines.first else { continue }
            // Two equally close names cannot be associated with one title reliably.
            if artistLines.count > 1 &&
                abs(artistLines[1].1 - closest.1) <= max(0.005, titleLine.rect.height * 0.25) {
                continue
            }
            candidates.append((QQSongCandidate(title: request.title, artist: closest.0.text,
                                               region: titleLine.rect),
                               parsed.originalTag || nearbyText.contains(where: Self.isOriginalTag)))
        }

        guard !candidates.isEmpty else { throw QQSongSearchError.notFound }
        if candidates.count == 1 { return candidates[0].song }
        let originalTagged = candidates.filter(\.originalTag)
        if request.version == .original && originalTagged.count == 1 {
            return originalTagged[0].song
        }
        throw QQSongSearchError.ambiguous
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "zh_CN"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func parseTitle(_ text: String, expected: String) -> (annotation: String, originalTag: Bool)? {
        let value = normalized(text)
        guard value.hasPrefix(expected) else { return nil }
        let suffix = String(value.dropFirst(expected.count))
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "()（）[]【】-—·:")))
        guard suffix.isEmpty || isKnownVersionAnnotation(suffix) else { return nil }
        return (suffix, isOriginalTag(suffix))
    }

    private static func isOriginalTag(_ value: String) -> Bool {
        let text = normalized(value)
        return text == "原唱" || text == "原版" || text == "original"
    }

    private static func isKnownVersionAnnotation(_ value: String) -> Bool {
        let text = normalized(value)
        return isOriginalTag(text) || variant(in: text).live || variant(in: text).alternative
    }

    private static func isInterfaceLabel(_ value: String) -> Bool {
        ["搜索结果", "单曲", "歌曲", "歌手", "专辑", "播放", "暂停", "收藏", "更多",
         "评论", "热门搜索", "推荐", "排行榜", "查看全部"].contains(value)
    }

    private static func variant(in value: String) -> (live: Bool, alternative: Bool) {
        let text = normalized(value)
        let live = ["live", "现场", "演唱会", "实况"].contains { text.contains($0) }
        let alternative = ["remix", "混音", "伴奏", "instrumental", "karaoke", "翻唱", "cover",
                           "全景声", "dolby", "dj", "acoustic", "纯音乐", "剪辑", "加速", "慢速"].contains {
            text.contains($0)
        }
        return (live, alternative)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite &&
        rect.minX >= 0 && rect.minY >= 0 && rect.width > 0 && rect.height > 0 &&
        rect.maxX <= 1 && rect.maxY <= 1
    }

    private static func isSameRow(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let overlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
        return overlap >= min(lhs.height, rhs.height) * 0.35
    }

    private static func isArtistBelow(_ candidate: CGRect, title: CGRect) -> Bool {
        let gap = candidate.minY - title.maxY
        return gap >= -min(candidate.height, title.height) * 0.2 &&
            gap <= min(0.07, max(0.012, title.height * 2.5)) &&
            abs(candidate.minX - title.minX) <= max(0.025, title.height * 1.5)
    }
}
