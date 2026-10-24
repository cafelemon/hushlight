import CoreGraphics
import Foundation

enum AutomaticWindowSelectionChoice: Sendable, Equatable {
    case selected(index: Int)
    case notFound
    case ambiguous
    case lowConfidence
}

/// Chooses an index from the supplied OCR observations, never arbitrary coordinates.
/// Implementations may use an explicitly configured analysis-only Agent.
protocol AutomaticWindowTextSelecting: Sendable {
    func select(targetText: String, lines: [WindowVisionLine]) async throws -> AutomaticWindowSelectionChoice
}

struct ExactWindowTextSelector: AutomaticWindowTextSelecting {
    let minimumConfidence: Float

    init(minimumConfidence: Float = 0.70) {
        self.minimumConfidence = minimumConfidence
    }

    func select(targetText: String, lines: [WindowVisionLine]) -> AutomaticWindowSelectionChoice {
        let target = Self.normalized(targetText)
        guard !target.isEmpty else { return .notFound }
        let matches = lines.enumerated().filter { _, line in
            Self.normalized(line.text) == target && Self.valid(line.rect)
        }
        // Even overlapping OCR observations can refer to two controls. Do not guess.
        guard matches.count <= 1 else { return .ambiguous }
        guard let match = matches.first else { return .notFound }
        guard match.element.confidence.isFinite,
              match.element.confidence >= minimumConfidence else { return .lowConfidence }
        return .selected(index: match.offset)
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "zh_CN"))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func valid(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite &&
        rect.width.isFinite && rect.height.isFinite &&
        rect.minX >= 0 && rect.minY >= 0 &&
        rect.width > 0 && rect.height > 0 &&
        rect.maxX <= 1 && rect.maxY <= 1
    }
}

enum AutomaticWindowSelectionError: Error, Equatable {
    case emptyTarget
    case unauthorized
    case unverifiedWindow
    case notFound
    case ambiguous
    case lowConfidence
}

struct AutomaticWindowSelectionResult: Sendable {
    let preview: WindowVisionPreview
    /// Normalized window coordinates, origin at top left.
    let region: CGRect
    /// Contains only the selected line; full-window OCR stays inside this service.
    let result: WindowVisionResult
    let attempts: Int
}

struct AutomaticWindowSelectionService: Sendable {
    private let backend: any WindowVisionProviding
    private let selector: any AutomaticWindowTextSelecting
    private static let fullWindow = CGRect(x: 0, y: 0, width: 1, height: 1)

    init(backend: any WindowVisionProviding = NativeWindowVisionBackend(),
         selector: any AutomaticWindowTextSelecting = ExactWindowTextSelector()) {
        self.backend = backend
        self.selector = selector
    }

    func select(window: WindowVisionWindow, targetText: String,
                authorize: @escaping @Sendable () async -> Bool) async throws -> AutomaticWindowSelectionResult {
        guard !ExactWindowTextSelector.normalized(targetText).isEmpty else {
            throw AutomaticWindowSelectionError.emptyTarget
        }
        guard WindowVisionSizePolicy.accepts(width: window.width, height: window.height) else {
            throw WindowVisionError.invalidWindow
        }
        var lastSelectionError: AutomaticWindowSelectionError = .notFound
        for attempt in 1...2 {
            try await requireAuthorization(authorize)
            guard await backend.permissionGranted() else { throw WindowVisionError.permissionRequired }
            try await requireAuthorization(authorize)

            let preview = try await backend.capturePreview(window: window)
            try await requireAuthorization(authorize)
            guard preview.window == window else { throw AutomaticWindowSelectionError.unverifiedWindow }

            let recognized = try await backend.recognize(preview: preview, region: Self.fullWindow)
            try await requireAuthorization(authorize)
            guard recognized.window == window, recognized.checkedAt == preview.checkedAt else {
                throw AutomaticWindowSelectionError.unverifiedWindow
            }

            switch try await selector.select(targetText: targetText, lines: recognized.lines) {
            case .selected(let index):
                guard recognized.lines.indices.contains(index) else {
                    throw AutomaticWindowSelectionError.unverifiedWindow
                }
                let line = recognized.lines[index]
                guard line.confidence.isFinite, line.confidence >= 0.70 else {
                    throw AutomaticWindowSelectionError.lowConfidence
                }
                guard ExactWindowTextSelector.valid(line.rect),
                      WindowVisionRegionPolicy.pixelRect(line.rect, image: preview.image) != nil else {
                    throw AutomaticWindowSelectionError.unverifiedWindow
                }
                try await requireAuthorization(authorize)
                return AutomaticWindowSelectionResult(
                    preview: preview, region: line.rect,
                    result: WindowVisionResult(window: window, checkedAt: recognized.checkedAt,
                                               lines: [line]), attempts: attempt)
            case .notFound:
                lastSelectionError = .notFound
            case .ambiguous:
                lastSelectionError = .ambiguous
            case .lowConfidence:
                lastSelectionError = .lowConfidence
            }
        }
        throw lastSelectionError
    }

    private func requireAuthorization(_ authorize: @Sendable () async -> Bool) async throws {
        try Task.checkCancellation()
        guard await authorize() else { throw AutomaticWindowSelectionError.unauthorized }
        try Task.checkCancellation()
    }
}
