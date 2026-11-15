import AppKit
import XCTest
import ReaderCore
@testable import MudsReader

private final class ControlledReaderIO: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var mainThread = false
    private var didBlock = false
    let blocked: String?
    let started: XCTestExpectation?
    let release = DispatchSemaphore(value: 0)
    let failed: Set<String>
    init(blocked: String? = nil, started: XCTestExpectation? = nil, failed: Set<String> = []) { self.blocked = blocked; self.started = started; self.failed = failed }
    func call(_ value: String) throws {
        lock.lock(); recorded.append(value); mainThread = mainThread || Thread.isMainThread
        let shouldBlock = value == blocked && !didBlock
        if shouldBlock { didBlock = true }
        lock.unlock()
        if shouldBlock {
            started?.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw ReaderError.invalid("Synthetic gate was not released") }
        }
        if failed.contains(value) { throw ReaderError.invalid("Synthetic failure: \(value)") }
    }
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    var usedMainThread: Bool { lock.lock(); defer { lock.unlock() }; return mainThread }
}

final class ReaderRoundTwoWorkflowTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @MainActor private func prepare(_ app: ReaderApp) throws {
        _ = NSApplication.shared
        try app.loadLibrary()
        app.window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 680, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        app.window.isReleasedWhenClosed = false; app.window.contentView = app.normalSurface
        app.mini = StealthWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 150), styleMask: [.borderless], backing: .buffered, defer: false)
        app.mini.isReleasedWhenClosed = false; app.mini.contentView = app.miniSurface
        app.table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("chapter")))
        app.table.dataSource = app
        app.state.preferences.adaptiveText = false
        app.importsReady = true
        app.errorHandler = { XCTFail("Unexpected error: \($0)") }
    }
    @MainActor private func finish(_ app: ReaderApp) async throws {
        app.invalidateReadingIntent(); await app.waitForChapterLoad(); await app.waitForImports()
        app.saveWork?.cancel(); try await app.persistence.flush(app.state).get()
        app.window.close(); app.mini.close(); app.settings?.close(); app.contrast.stop(); app.miniSurface.interaction.setHoverTracking(false)
    }
    private func makeBook(_ name: String, title: String? = nil, chapters: Int = 4) throws -> Book {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try Data("<container><rootfiles><rootfile full-path='book.opf'/></rootfiles></container>".utf8).write(to: directory.appendingPathComponent("META-INF/container.xml"))
        let manifest = (0..<chapters).map { "<item id='c\($0)' href='chapter\($0).xhtml' media-type='application/xhtml+xml'/>" }.joined()
        let spine = (0..<chapters).map { "<itemref idref='c\($0)'/>" }.joined()
        try Data("<package><metadata><title>\(title ?? name)</title></metadata><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>".utf8).write(to: directory.appendingPathComponent("book.opf"))
        for chapter in 0..<chapters { try Data("<html><body><p>\(name) chapter \(chapter)</p><p>\(String(repeating: "Synthetic reading text. ", count: 200))</p></body></html>".utf8).write(to: directory.appendingPathComponent("chapter\(chapter).xhtml")) }
        return try EPUB.load(directory: directory)
    }

    @MainActor func testSameTitlePickerUsesBookIdentityAndFailedClickRestoresTOC() async throws {
        let app = ReaderApp(support: root.appendingPathComponent("support")); try prepare(app)
        let books = try [makeBook("A", title: "Same"), makeBook("B", title: "Same"), makeBook("C", title: "Other")]
        app.state.books = books; app.refreshLibrary()
        XCTAssertEqual(app.bookPicker.numberOfItems, 3)
        for book in books {
            let item = try XCTUnwrap(app.bookPicker.itemArray.first { ($0.representedObject as? String) == book.id })
            app.bookPicker.select(item); app.selectBook(); await app.waitForChapterLoad()
            XCTAssertEqual(app.displayedBookID, book.id); XCTAssertTrue(app.currentText.hasPrefix(String(book.directory.split(separator: "/").last!) + " chapter 0"))
        }
        let original = app.currentText, position = app.state.positions[books[2].id]
        try FileManager.default.removeItem(at: URL(fileURLWithPath: books[2].directory).appendingPathComponent("chapter1.xhtml"))
        var errors: [Error] = []; app.errorHandler = { errors.append($0) }
        app.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false); app.selectChapter(); await app.waitForChapterLoad()
        XCTAssertEqual(errors.count, 1); XCTAssertEqual(app.currentText, original); XCTAssertEqual(app.currentChapter, 0)
        XCTAssertEqual(app.table.selectedRow, 0); XCTAssertEqual(app.chapterLabel.stringValue, books[2].chapters[0].title)
        XCTAssertEqual(app.state.positions[books[2].id], position)
        app.search.stringValue = "章节 2"; app.filterChapters(); XCTAssertEqual(app.filtered, [1]); XCTAssertEqual(app.table.selectedRow, 0)
        try await finish(app)
    }

    @MainActor func testChapterLoadsCoalesceAndIgnoreStaleFailure() async throws {
        let began = expectation(description: "second chapter started")
        let started = ControlledReaderIO(blocked: "1", started: began, failed: ["1"])
        defer { started.release.signal() }
        let app = ReaderApp(support: root.appendingPathComponent("support"), chapterLoader: { book, index in try started.call(String(index)); return try book.text(at: index) })
        try prepare(app); let book = try makeBook("A"); app.state.books = [book]
        app.openBook(book, chapter: 0); await app.waitForChapterLoad()
        app.openChapter(1); await fulfillment(of: [began], timeout: 2)
        XCTAssertEqual(app.currentChapter, 0)
        app.window.orderFront(nil)
        app.nextChapter(); app.nextChapter()
        started.release.signal(); await app.waitForChapterLoad()
        XCTAssertEqual(started.calls, ["0", "1", "3"]); XCTAssertFalse(started.usedMainThread)
        XCTAssertEqual(app.currentChapter, 3); XCTAssertTrue(app.currentText.hasPrefix("A chapter 3"))
        try await finish(app)
    }

    @MainActor func testHiddenReaderRejectsLateImportDisplay() async throws {
        let began = expectation(description: "import started")
        let importer = ControlledReaderIO(blocked: "incoming", started: began)
        defer { importer.release.signal() }
        let current = try makeBook("Current"), incoming = try makeBook("Incoming")
        let app = ReaderApp(support: root.appendingPathComponent("support"), bookImporter: { url, _ in try importer.call(url.lastPathComponent); return (incoming, try incoming.text(at: 0)) })
        try prepare(app); app.state.books = [current]; app.openBook(current, chapter: 0); await app.waitForChapterLoad()
        var completed: [Bool] = []
        app.importURLs([root.appendingPathComponent("incoming")]) { completed.append($0) }
        await fulfillment(of: [began], timeout: 2); XCTAssertTrue(completed.isEmpty)
        app.hideReader(); importer.release.signal(); await app.waitForImports()
        XCTAssertEqual(completed, [true]); XCTAssertEqual(app.state.books.count, 2); XCTAssertEqual(app.displayedBookID, current.id)
        XCTAssertFalse(app.window.isVisible); XCTAssertFalse(app.mini.isVisible)
        XCTAssertEqual(try LibraryState.load(from: app.stateURL).books.count, 2)
        try await finish(app)
    }

    @MainActor func testSwitchSamplesLatestOldPositionAndHideCancelsLateSuccess() async throws {
        let began = expectation(description: "book B started"), b = try makeBook("B"), a = try makeBook("A")
        let loader = ControlledReaderIO(blocked: b.id, started: began)
        defer { loader.release.signal() }
        let app = ReaderApp(support: root.appendingPathComponent("support"), chapterLoader: { book, chapter in try loader.call(book.id); return try book.text(at: chapter) })
        try prepare(app); app.state.books = [a,b]; app.openBook(a, chapter: 0); await app.waitForChapterLoad()
        app.openBook(b, chapter: 0); await fulfillment(of: [began], timeout: 2)
        app.active.restore(1500); let latest = app.active.visibleCharacter(); XCTAssertGreaterThan(latest, 0)
        loader.release.signal(); await app.waitForChapterLoad()
        XCTAssertEqual(app.state.positions[a.id]?.character, latest); XCTAssertEqual(app.displayedBookID, b.id)
        // The main-actor request can be invalidated before its background job is launched.
        app.openBook(a, chapter: 1); app.hideReader(); await app.waitForChapterLoad()
        XCTAssertEqual(app.displayedBookID, b.id); XCTAssertEqual(app.currentChapter, 0); XCTAssertFalse(app.window.isVisible)
        try await finish(app)
    }

    @MainActor func testHideDiscardsAnInFlightSuccessEvenIfLoaderIgnoresCancellation() async throws {
        let began = expectation(description: "late chapter started"), gate = ControlledReaderIO(blocked: "1", started: began)
        defer { gate.release.signal() }
        let app = ReaderApp(support: root.appendingPathComponent("support"), chapterLoader: { _, chapter in
            try gate.call(String(chapter)); return "Synthetic chapter \(chapter)"
        })
        try prepare(app); let book = try makeBook("A"); app.state.books = [book]
        app.openBook(book, chapter: 0); await app.waitForChapterLoad()
        app.openChapter(1); await fulfillment(of: [began], timeout: 2)
        app.hideReader(); gate.release.signal(); await app.waitForChapterLoad()
        XCTAssertEqual(app.currentChapter, 0); XCTAssertEqual(app.currentText, "Synthetic chapter 0")
        XCTAssertFalse(app.window.isVisible); XCTAssertNil(app.requestedChapter)
        try await finish(app)
    }

    @MainActor func testQueuedImportBatchesReplyOnceAfterPersistenceAndKeepMixedSuccess() async throws {
        let began = expectation(description: "first import started")
        let gate = ControlledReaderIO(blocked: "A", started: began, failed: ["bad"])
        defer { gate.release.signal() }
        let a = try makeBook("A"), b = try makeBook("B"), c = try makeBook("C")
        let books = ["A": a, "B": b, "C": c]
        let writes = ControlledReaderIO()
        let app = ReaderApp(support: root.appendingPathComponent("support"), bookImporter: { url, _ in
            try gate.call(url.lastPathComponent)
            let book = books[url.lastPathComponent]!; return (book, try book.text(at: 0))
        }, libraryWriter: { state, url in try writes.call(String(state.books.count)); try state.save(to: url) })
        try prepare(app); var replies: [String] = [], errors: [Error] = []; app.errorHandler = { errors.append($0) }
        app.importURLs([root.appendingPathComponent("A"), root.appendingPathComponent("bad"), root.appendingPathComponent("B")]) { success in
            replies.append("first:\(success)")
            XCTAssertEqual(try? LibraryState.load(from: app.stateURL).books.count, 2)
        }
        await fulfillment(of: [began], timeout: 2)
        app.importURLs([root.appendingPathComponent("C")]) { success in
            replies.append("second:\(success)"); XCTAssertEqual(try? LibraryState.load(from: app.stateURL).books.count, 3)
        }
        XCTAssertTrue(replies.isEmpty); gate.release.signal(); await app.waitForImports()
        XCTAssertEqual(gate.calls, ["A", "bad", "B", "C"]); XCTAssertEqual(replies, ["first:false", "second:true"])
        XCTAssertEqual(errors.count, 1); XCTAssertEqual(app.state.books.map(\.id), [a.id, b.id, c.id]); XCTAssertEqual(app.displayedBookID, c.id)
        XCTAssertFalse(gate.usedMainThread); XCTAssertFalse(writes.usedMainThread)
        try await finish(app)
    }

    @MainActor func testBeforeLaunchBatchWaitsForLibraryAndRejectsEmptyBatchOnce() async throws {
        let incoming = try makeBook("Incoming"), calls = ControlledReaderIO()
        let app = ReaderApp(support: root.appendingPathComponent("support"), bookImporter: { url, _ in try calls.call(url.lastPathComponent); return (incoming, try incoming.text(at: 0)) })
        var replies: [Bool] = []
        app.importURLs([root.appendingPathComponent("incoming")]) { replies.append($0) }
        XCTAssertTrue(calls.calls.isEmpty); XCTAssertTrue(replies.isEmpty)
        try prepare(app); app.startPendingImports(); await app.waitForImports()
        XCTAssertEqual(replies, [true]); XCTAssertEqual(calls.calls, ["incoming"])
        app.importURLs([]) { replies.append($0) }; XCTAssertEqual(replies, [true, false])
        try await finish(app)
    }

    @MainActor func testPersistenceCoalescesPendingSnapshotsAndQuitWaitsForFinalWrite() async throws {
        let began = expectation(description: "first write began"), writer = ControlledReaderIO(blocked: "21", started: began)
        defer { writer.release.signal() }
        let app = ReaderApp(support: root.appendingPathComponent("support"), libraryWriter: { state, url in try writer.call(String(Int(state.preferences.fontSize))); try state.save(to: url) })
        try prepare(app)
        app.state.preferences.fontSize = 21; app.persist(); await fulfillment(of: [began], timeout: 2)
        app.state.preferences.fontSize = 22; app.persist()
        app.state.preferences.fontSize = 23; app.persist()
        let finalRevision = app.persistence.revision
        app.persist(); XCTAssertEqual(app.persistence.revision, finalRevision)
        let replied = expectation(description: "quit reply"); var replies: [Bool] = []
        app.terminationReply = { replies.append($0); replied.fulfill() }
        XCTAssertEqual(app.applicationShouldTerminate(NSApplication.shared), .terminateLater); XCTAssertTrue(replies.isEmpty)
        writer.release.signal(); await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(replies, [true]); XCTAssertEqual(writer.calls, ["21", "23"]); XCTAssertFalse(writer.usedMainThread)
        XCTAssertEqual(try LibraryState.load(from: app.stateURL).preferences.fontSize, 23)
        try await finish(app)
    }

    @MainActor func testImportWriteFailureIsFailureAndUnchangedFailureDoesNotLoop() async throws {
        let incoming = try makeBook("Incoming"), writer = ControlledReaderIO(failed: ["write"])
        let app = ReaderApp(support: root.appendingPathComponent("support"), bookImporter: { _, _ in (incoming, try incoming.text(at: 0)) }, libraryWriter: { _, _ in try writer.call("write") })
        try prepare(app); var errors: [Error] = [], replies: [Bool] = []
        app.errorHandler = { errors.append($0); app.persist() }
        app.importURLs([root.appendingPathComponent("incoming")]) { replies.append($0) }; await app.waitForImports()
        XCTAssertEqual(replies, [false]); XCTAssertNil(app.displayedBookID); XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(writer.calls, ["write"]); XCTAssertFalse(FileManager.default.fileExists(atPath: app.stateURL.path))
        app.window.close(); app.mini.close()
    }

    @MainActor func testLegacyPositionReopensChapterStartWithNoticeAndRecoveryMetadata() async throws {
        let book = try makeBook("Legacy"), app = ReaderApp(support: root.appendingPathComponent("support")); try prepare(app)
        let old = try JSONDecoder().decode(ReadingPosition.self, from: Data(#"{"chapter":2,"character":1900}"#.utf8))
        app.state.books = [book]; app.state.positions[book.id] = old
        app.openBook(book, chapter: old.chapter, position: old); await app.waitForChapterLoad()
        XCTAssertEqual(app.currentChapter, 2); XCTAssertEqual(app.active.visibleCharacter(), 0)
        XCTAssertTrue(app.subtitleLabel.stringValue.contains("从章首继续"))
        app.openChapter(3); await app.waitForChapterLoad(); try await app.persistence.flush(app.state).get()
        let saved = try XCTUnwrap(LibraryState.load(from: app.stateURL).positions[book.id])
        XCTAssertEqual(saved.legacyChapter, 2); XCTAssertEqual(saved.legacyCharacter, 1900); XCTAssertFalse(saved.requiresTextMigration)
        try await finish(app)
    }

    @MainActor func testHiddenSettingsUnchangedLimitsAndInactiveTypographyDoNoExtraWork() async throws {
        let app = ReaderApp(support: root.appendingPathComponent("support")); try prepare(app)
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 336, height: 347), styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; app.settings = panel; app.rebuildSettings()
        let content = panel.contentView
        app.state.preferences.fontSize = 32; app.state.preferences.brightness = 1; app.state.preferences.opacity = 0.9234
        let revision = app.persistence.revision
        app.larger(); app.brighter(); XCTAssertEqual(app.persistence.revision, revision); XCTAssertNil(app.saveWork)
        app.dimmer(); XCTAssertEqual(app.state.preferences.opacity, 0.9234); XCTAssertTrue(panel.contentView === content)
        app.saveWork?.cancel(); app.saveWork = nil
        let slider = NSSlider(value: 19, minValue: 8, maxValue: 20, target: nil, action: nil); slider.tag = 1
        let originalText = app.active.text.attributedString()
        app.sliderChanged(slider); XCTAssertEqual(app.active.text.attributedString(), originalText)
        let preferences = app.state.preferences; slider.tag = 999; slider.doubleValue = 44; app.sliderChanged(slider)
        XCTAssertEqual(app.state.preferences, preferences); XCTAssertTrue(panel.contentView === content)
        panel.orderFront(nil); app.refreshVisibleSettings(); XCTAssertTrue(panel.contentView === content)
        try await finish(app)
    }
}
