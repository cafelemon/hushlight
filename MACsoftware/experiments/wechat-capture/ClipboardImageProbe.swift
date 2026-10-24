// User-triggered native screenshot diagnostic. Never reads clipboard text or writes images.
import AppKit
import Vision

@main struct ClipboardImageProbe {
    @MainActor static func main() {
        let pasteboard = NSPasteboard.general
        let args = CommandLine.arguments
        func emit(_ result: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys) else { return }
            print(String(decoding: data, as: UTF8.self))
        }
        if args.dropFirst() == ["--baseline"] {
            emit(["change_count": pasteboard.changeCount]); return
        }
        guard args.count == 3, args[1] == "--after", let previous = Int(args[2]),
              pasteboard.changeCount != previous else {
            emit(["status": "blocked", "reason": "new_clipboard_generation_required"]); return
        }
        let count = pasteboard.changeCount
        guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
              data.count <= 80_000_000, let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            emit(["status": "blocked", "reason": "new_clipboard_is_not_supported_image"]); return
        }
        guard cg.width > 0, cg.height > 0, cg.width <= 10_000, cg.height <= 10_000,
              cg.width * cg.height <= 40_000_000 else {
            emit(["status": "blocked", "reason": "image_limit_exceeded"]); return
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "zh-Hans"]
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: cg).perform([request])
            guard pasteboard.changeCount == count else {
                emit(["status": "blocked", "reason": "clipboard_changed_during_read"]); return
            }
            let texts = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            emit(["status": "completed", "clipboard_changed": true,
                  "width": cg.width, "height": cg.height,
                  "test_text_match": texts.joined(separator: " ").contains("ORBIT_CAPTURE_TEST_20261024"),
                  "ocr_line_count": texts.count, "saved_image": false])
        } catch { emit(["status": "blocked", "reason": "local_ocr_failed"]) }
    }
}
