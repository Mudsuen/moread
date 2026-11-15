import XCTest
@testable import ReaderCore

final class ReaderRoundTwoTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func write(_ path: String, _ contents: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func testLiteralPercentPathsSurviveDirectoryZipAndSavedLibrary() throws {
        try write("source/META-INF/container.xml", "<container><rootfiles><rootfile full-path='OEBPS/book%2520name.opf'/></rootfiles></container>")
        try write("source/OEBPS/book%20name.opf", "<package><metadata><title>Percent</title></metadata><manifest><item id='c' href='chapter%2520one.xhtml?query=1#start' media-type='application/xhtml+xml'/><item id='toc' href='toc.xhtml' media-type='application/xhtml+xml' properties='nav'/></manifest><spine><itemref idref='c'/></spine></package>")
        try write("source/OEBPS/toc.xhtml", "<html xmlns:epub='http://www.idpf.org/2007/ops'><body><nav epub:type='toc'><a href='chapter%2520one.xhtml#start'>Correct chapter</a></nav></body></html>")
        try write("source/OEBPS/chapter%20one.xhtml", "<html><body><p>Literal percent target</p></body></html>")
        try write("source/OEBPS/chapter one.xhtml", "<html><body><p>Wrong space target</p></body></html>")
        let source = root.appendingPathComponent("source"), archive = root.appendingPathComponent("book.epub")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.arguments = ["-qr", archive.path, "META-INF", "OEBPS"]; zip.currentDirectoryURL = source
        try zip.run(); zip.waitUntilExit(); XCTAssertEqual(zip.terminationStatus, 0)
        for input in [source, archive] {
            let book = try EPUB.importBook(from: input, library: root.appendingPathComponent(UUID().uuidString))
            XCTAssertEqual(book.chapters.first?.path, "OEBPS/chapter%20one.xhtml")
            XCTAssertEqual(book.chapters.first?.title, "Correct chapter")
            var library = LibraryState(); library.books = [book]; library.selectedBook = book.id
            let json = root.appendingPathComponent("library.json"); try library.save(to: json)
            let restored = try LibraryState.load(from: json)
            XCTAssertEqual(try restored.books[0].text(at: 0), "Literal percent target")
        }
        XCTAssertEqual(try EPUB.relativePath(for: "%252e%252e/ch.xhtml", from: root, under: root), "%2e%2e/ch.xhtml")
        XCTAssertEqual(try EPUB.relativePath(for: "中文%20%25.xhtml#part", from: root, under: root), "中文 %.xhtml")
        XCTAssertEqual(try EPUB.safeURL("%2e%2e/ch.xhtml", under: root).lastPathComponent, "ch.xhtml")
        for reference in ["%2e%2e/outside", "%2Fetc/passwd", "https://example.org/ch.xhtml", "broken%zz.xhtml"] {
            XCTAssertThrowsError(try EPUB.relativePath(for: reference, from: root, under: root))
        }
    }

    func testStrictUTF8UTF16AndCDATAHaveIdenticalText() throws {
        let body = "<html><body><p>中文🙂 &nbsp;&mdash;</p><p><![CDATA[&nbsp; &mdash; &amp; 中文🙂]]></p><p>&amp;nbsp; &amp;mdash;</p></body></html>"
        let expected = "中文🙂 \u{00A0}—\n\n&nbsp; &mdash; &amp; 中文🙂\n\n&nbsp; &mdash;"
        let utf8 = Data(("<?xml version='1.0' encoding='UTF-8'?>" + body).utf8)
        var le = Data([0xFF, 0xFE]); le.append(("<?xml version='1.0' encoding='UTF-16'?>" + body).data(using: .utf16LittleEndian)!)
        var be = Data([0xFE, 0xFF]); be.append(("<?xml version='1.0' encoding='UTF-16BE'?>" + body).data(using: .utf16BigEndian)!)
        for data in [utf8, le, be] { XCTAssertEqual(try EPUB.plainText(data), expected) }
        var invalid = Data("<html><body>bad ".utf8); invalid.append(0xFF); invalid.append(Data(" byte</body></html>".utf8))
        XCTAssertThrowsError(try EPUB.plainText(invalid))
        var mismatch = Data([0xFF, 0xFE]); mismatch.append(("<?xml version='1.0' encoding='UTF-8'?>" + body).data(using: .utf16LittleEndian)!)
        XCTAssertThrowsError(try EPUB.plainText(mismatch))
        XCTAssertThrowsError(try EPUB.plainText(Data([0xFF, 0xFE, 0x00, 0xD8])))
        XCTAssertThrowsError(try EPUB.plainText(Data(("<?xml version='1.0' encoding='ISO-8859-1'?>" + body).utf8)))
        let contexts = "<?xml version='1.0'?><!-- &nbsp; --><?sample &mdash;?><html><body><p><![CDATA[&nbsp;]]></p><p>&nbsp;</p></body></html>"
        let normalized = try EPUB.normalizedXML(Data(contexts.utf8))
        XCTAssertTrue(normalized.contains("<!-- &nbsp; --><?sample &mdash;?>"))
        XCTAssertTrue(normalized.contains("<![CDATA[&nbsp;]]>"))
        XCTAssertTrue(normalized.contains("<p>&#160;</p>"))
    }

    func testSourceWhitespaceBreaksPreAndTableStructureAreDistinct() throws {
        let source = "<html><body>\n<p>Hello\n    <em>world</em></p><p>A<br/>B</p><pre>if x:\n    print(x)\n\nend</pre><h5>Heading</h5><table><tr><th>A</th><th>B</th></tr><tr><td>C</td><td>D</td></tr></table>\n</body></html>"
        XCTAssertEqual(try EPUB.plainText(Data(source.utf8)), "Hello world\n\nA\nB\n\nif x:\n    print(x)\n\nend\n\nHeading\n\nA\tB\n\nC\tD")
        XCTAssertEqual(try EPUB.plainText(Data("<html><body><p>Hello world</p></body></html>".utf8)), "Hello world")
    }

    func testExistingPositionsExplicitlyCarryLegacyExtractionVersion() throws {
        let old = try JSONDecoder().decode(ReadingPosition.self, from: Data(#"{"chapter":3,"character":891}"#.utf8))
        XCTAssertEqual(old.character, 891); XCTAssertTrue(old.requiresTextMigration)
        let migrated = ReadingPosition(chapter: old.chapter, character: 0, legacyCharacter: old.character, legacyChapter: old.chapter)
        let restored = try JSONDecoder().decode(ReadingPosition.self, from: JSONEncoder().encode(migrated))
        XCTAssertFalse(restored.requiresTextMigration); XCTAssertEqual(restored.chapter, 3); XCTAssertEqual(restored.character, 0); XCTAssertEqual(restored.legacyCharacter, 891); XCTAssertEqual(restored.legacyChapter, 3)
    }
}
