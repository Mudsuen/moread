import AppKit
import XCTest
import ReaderCore
@testable import MudsReader

final class ReaderAppearanceTests: XCTestCase {
    func testAppearanceChangesPreserveTextPaginationSelectionAndAnchor() {
        _ = NSApplication.shared
        let content = (0..<120).map { "Paragraph \($0) — 原创中文测试与👨‍👩‍👧‍👦组合字符。 Continued reading text." }.joined(separator: "\n\n")
        for (mode, stealth) in [(ReadingMode.paged, false), (.paged, true), (.scrolling, false), (.scrolling, true)] {
            let view = ReaderSurface(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
            show(content, in: view, mode: mode, stealth: stealth)
            view.restore(700)
            let anchor = view.visibleCharacter(), ranges = view.pageRanges, visible = view.text.string
            let selection = NSRange(location: 12, length: 6)
            view.text.setSelectedRange(selection)
            let recorder = CharacterEditRecorder()
            view.text.textStorage?.delegate = recorder
            show(content, in: view, mode: mode, character: anchor, brightness: 0.5, dark: false, opacity: 0.2, stealth: stealth)
            XCTAssertEqual(recorder.characterEdits, 0, "Appearance changes must not replace or repaginate chapter text")
            XCTAssertEqual(view.visibleCharacter(), anchor)
            XCTAssertEqual(view.pageRanges, ranges)
            XCTAssertEqual(view.text.string, visible)
            XCTAssertEqual(view.text.selectedRange(), selection)
            let reference = ReaderSurface(frame: view.frame)
            show(content, in: reference, mode: mode, character: anchor, brightness: 0.5, dark: false, opacity: 0.2, stealth: stealth)
            XCTAssertEqual(view.foregroundColor, reference.foregroundColor)
            XCTAssertEqual(view.text.string, reference.text.string)
            if mode == .paged { XCTAssertEqual(view.pageRanges, reference.pageRanges) }
        }
    }

    func testAppearanceReuseStillHonorsNavigationAndTypographyChanges() {
        _ = NSApplication.shared
        let content = String(repeating: "A line of original text 中文测试。\n\n", count: 60)
        let view = ReaderSurface(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
        show(content, in: view, mode: .paged)
        let previousRange = view.displayedRange
        let target = view.pageRanges[2].location
        show(content, in: view, mode: .paged, character: target, brightness: 0.7)
        XCTAssertNotEqual(view.displayedRange, previousRange)
        XCTAssertEqual(view.visibleCharacter(), target)
        view.display(content, fontSize: 18, brightness: 0.7, stealth: true, character: target,
                     dark: true, fontName: "mono", lineHeight: 1.6, paragraphSpacing: 9, margin: 12)
        let reference = ReaderSurface(frame: view.frame)
        reference.display(content, fontSize: 18, brightness: 0.7, stealth: true, character: target,
                          dark: true, fontName: "mono", lineHeight: 1.6, paragraphSpacing: 9, margin: 12)
        XCTAssertEqual(view.pageRanges, reference.pageRanges)
        XCTAssertEqual(view.text.string, reference.text.string)
        XCTAssertEqual(view.visibleCharacter(), reference.visibleCharacter())
    }

    func testReturningToOtherReaderSurfaceUsesItsExactIncomingAnchor() {
        _ = NSApplication.shared
        let content = String(repeating: "Original reading text with stable character positions.\n\n", count: 100)
        let compact = ReaderSurface(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
        let normal = ReaderSurface(frame: NSRect(x: 0, y: 0, width: 680, height: 400))
        show(content, in: compact, mode: .paged)
        let target = compact.pageRanges[2].location + 3
        XCTAssertFalse(compact.pageRanges.contains { $0.location == target })
        show(content, in: normal, mode: .paged, character: target, stealth: false)
        let incomingAnchor = normal.visibleCharacter()
        XCTAssertEqual(incomingAnchor, target)
        show(content, in: compact, mode: .paged, character: incomingAnchor)
        XCTAssertEqual(compact.visibleCharacter(), incomingAnchor, "Switching reader surfaces must not snap backward to an old page boundary")
        let reference = ReaderSurface(frame: compact.frame)
        show(content, in: reference, mode: .paged, character: incomingAnchor)
        XCTAssertEqual(compact.pageRanges, reference.pageRanges)
        XCTAssertEqual(compact.text.string, reference.text.string)
    }

    func testAppearanceReuseDoesNotConflateCanonicallyEquivalentSourceText() {
        _ = NSApplication.shared
        let view = ReaderSurface(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
        let composed = "Café source", decomposed = "Cafe\u{301} source"
        XCTAssertEqual(composed, decomposed)
        show(composed, in: view, mode: .scrolling)
        show(decomposed, in: view, mode: .scrolling)
        XCTAssertEqual(Array(view.text.string.utf16), Array(decomposed.utf16))
    }

    func testAppearanceVerificationRequiresAnExplicitAbsoluteFixturePath() throws {
        for arguments in [["moread"], ["moread", "--verify-appearance"],
                          ["moread", "--verify-appearance", "relative/book"],
                          ["moread", "--verify-appearance", "--import"]] {
            XCTAssertThrowsError(try ReaderAppearanceVerification.fixtureDirectory(arguments: arguments))
        }
        let url = try ReaderAppearanceVerification.fixtureDirectory(arguments: ["moread", "--verify-appearance", "/tmp/synthetic-book"])
        XCTAssertEqual(url.path, "/tmp/synthetic-book")
    }

    func testSyntheticEPUBAppearanceBenchmark() throws {
        guard ProcessInfo.processInfo.environment["MOREAD_RUN_BENCHMARKS"] == "1" else {
            throw XCTSkip("Opt in to the synthetic chapter appearance benchmark")
        }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "<container><rootfiles><rootfile full-path='book.opf'/></rootfiles></container>".write(to: root.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)
        try "<package><metadata><title>Synthetic appearance fixture</title></metadata><manifest><item id='chapter' href='chapter.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='chapter'/></spine></package>".write(to: root.appendingPathComponent("book.opf"), atomically: true, encoding: .utf8)
        let paragraphs = (0..<1200).map { "<p>Paragraph \($0): original synthetic text. 中文阅读与👨‍👩‍👧‍👦组合字符，保持阅读位置。 &amp; Additional words for layout.</p>" }.joined()
        try "<html><body>\(paragraphs)</body></html>".write(to: root.appendingPathComponent("chapter.xhtml"), atomically: true, encoding: .utf8)
        let book = try EPUB.load(directory: root), text = try book.text(at: 0)
        let view = ReaderSurface(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
        show(text, in: view, mode: .paged)
        let ranges = view.pageRanges
        var samples: [Double] = []
        for _ in 0..<3 {
            let start = ProcessInfo.processInfo.systemUptime
            for index in 0..<8 {
                show(text, in: view, mode: .paged, brightness: Double(index + 1) / 10,
                     dark: index.isMultiple(of: 2), opacity: Double(index) / 10)
                XCTAssertEqual(view.pageRanges, ranges)
                XCTAssertEqual(view.visibleCharacter(), 0)
                XCTAssertEqual(view.text.string, (text as NSString).substring(with: ranges[0]))
            }
            samples.append(ProcessInfo.processInfo.systemUptime - start)
        }
        print("MOREAD_APPEARANCE_BENCHMARK utf16=\(text.utf16.count) pages=\(ranges.count) updates=8 samples=\(samples) median_seconds=\(samples.sorted()[1])")

    }

    private func show(_ content: String, in view: ReaderSurface, mode: ReadingMode,
                      character: Int = 0, brightness: Double = 1, dark: Bool = true, opacity: Double = 1, stealth: Bool = true) {
        view.display(content, fontSize: 11, brightness: brightness, stealth: stealth, character: character,
                     dark: dark, fontName: "system", lineHeight: 1.15, paragraphSpacing: 3, margin: 48,
                     mode: mode, backgroundOpacity: opacity, textOpacity: 0.8)
    }
}

private final class CharacterEditRecorder: NSObject, NSTextStorageDelegate {
    var characterEdits = 0
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        if editedMask.contains(.editedCharacters) { characterEdits += 1 }
    }
}
