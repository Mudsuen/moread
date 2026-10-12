import XCTest
@testable import ReaderCore

final class ReaderCoreTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:root) }
    func write(_ path: String,_ text: String) throws { let url = root.appendingPathComponent(path); try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true); try text.write(to:url,atomically:true,encoding:.utf8) }
    func fixture() throws {
        try write("META-INF/container.xml","<container><rootfiles><rootfile full-path='OEBPS/book.opf'/></rootfiles></container>")
        try write("OEBPS/book.opf","""
        <package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>测试书</dc:title><dc:creator>作者</dc:creator></metadata><manifest><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="toc"><itemref idref="one"/><itemref idref="two"/></spine></package>
        """)
        try write("OEBPS/toc.ncx","<ncx><navMap><navPoint><navLabel><text>开篇</text></navLabel><content src='one.xhtml'/><navPoint><navLabel><text>第二章</text></navLabel><content src='two.xhtml#start'/></navPoint></navPoint></navMap></ncx>")
        try write("OEBPS/one.xhtml","<html><head><title>not body</title></head><body><h1>开篇</h1><p>你好，<em>世界</em>。</p><script>ignored</script><p style='display: none'>hidden</p><p>第二段&nbsp;末尾</p></body></html>")
        try write("OEBPS/two.xhtml","<html><body><p>第二章正文</p></body></html>")
    }
    func testSpineOrderNestedTOCAndChineseExtraction() throws {
        try fixture(); let book = try EPUB.load(directory:root)
        XCTAssertEqual(book.title,"测试书"); XCTAssertEqual(book.author,"作者"); XCTAssertEqual(book.chapters.map(\.title),["开篇","第二章"])
        let text = try book.text(at:0); XCTAssertTrue(text.contains("你好，世界。")); XCTAssertFalse(text.contains("hidden")); XCTAssertFalse(text.contains("not body")); XCTAssertFalse(text.contains("ignored")); XCTAssertEqual(try book.text(at:1),"第二章正文")
    }
    func testPathTraversalAndSymlinkRejected() throws {
        XCTAssertThrowsError(try EPUB.safeURL("../outside",under:root)); XCTAssertThrowsError(try EPUB.safeURL("%2e%2e/outside",under:root)); XCTAssertThrowsError(try EPUB.safeURL("/etc/passwd",under:root))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link"),withDestinationURL:URL(fileURLWithPath:"/etc"))
        XCTAssertThrowsError(try EPUB.safeURL("link/passwd",under:root))
    }
    func testImportCopyAndPositionPersistence() throws {
        try fixture(); let library = root.appendingPathComponent("imported"); let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        for name in ["META-INF","OEBPS"] { try FileManager.default.moveItem(at:root.appendingPathComponent(name),to:source.appendingPathComponent(name)) }
        let book = try EPUB.importBook(from:source,library:library); try FileManager.default.removeItem(at:source)
        XCTAssertEqual(try book.text(at:1),"第二章正文")
        var state = LibraryState(); state.books = [book]; state.selectedBook = book.id; state.positions[book.id] = ReadingPosition(chapter:1,character:23); state.preferences.opacity = 0.45; state.preferences.stealthFontSize = 9
        let file = root.appendingPathComponent("state.json"); try state.save(to:file); let loaded = try LibraryState.load(from:file)
        XCTAssertEqual(loaded.positions[book.id],ReadingPosition(chapter:1,character:23)); XCTAssertEqual(loaded.preferences.opacity,0.45); XCTAssertEqual(loaded.preferences.stealthFontSize,9)
    }
    func testOldPreferencesUpgradeWithoutLosingPosition() throws {
        let data = Data("{\"fontSize\":22,\"stealthFontSize\":9,\"brightness\":0.15,\"opacity\":0.65,\"floating\":true}".utf8)
        let p = try JSONDecoder().decode(ReaderPreferences.self,from:data)
        XCTAssertEqual(p.fontSize,22); XCTAssertEqual(p.stealthFontSize,9); XCTAssertEqual(p.theme,"system"); XCTAssertEqual(p.lineHeight,1.35)
    }
    func testMalformedHTMLRecovery() throws {
        let text = try EPUB.plainText(Data("<html><body><ol><li>正文未闭合</ol><p>后续正文</p></body></html>".utf8))
        XCTAssertTrue(text.contains("正文未闭合")); XCTAssertTrue(text.contains("后续正文"))
    }
    func testMalformedImportCleansUp() throws {
        let source = root.appendingPathComponent("bad.epub"); try Data("invalid".utf8).write(to:source)
        let library = root.appendingPathComponent("library"); XCTAssertThrowsError(try EPUB.importBook(from:source,library:library)); XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:library.path),[])
    }
    func testZippedImport() throws {
        try fixture(); let archive = root.appendingPathComponent("sample.epub")
        let p = Process(); p.executableURL = URL(fileURLWithPath:"/usr/bin/zip"); p.arguments = ["-qr",archive.path,"META-INF","OEBPS"]; p.currentDirectoryURL = root; try p.run(); p.waitUntilExit(); XCTAssertEqual(p.terminationStatus,0)
        let book = try EPUB.importBook(from:archive,library:root.appendingPathComponent("library")); XCTAssertEqual(book.chapters.count,2); XCTAssertEqual(try book.text(at:1),"第二章正文")
    }
}
