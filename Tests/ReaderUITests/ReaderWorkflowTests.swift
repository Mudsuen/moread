import AppKit
import XCTest
import ReaderCore
@testable import MudsReader

final class ReaderWorkflowTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:root) }

    @MainActor func testFailedLibraryLoadNeverWritesDefaultState() throws {
        var invalid = LibraryState()
        invalid.preferences.readingMode = .scrolling
        let invalidMode = String(data:try JSONEncoder().encode(invalid),encoding:.utf8)!.replacingOccurrences(of:"scrolling",with:"unknown")
        for contents in ["{\"books\":[",invalidMode] {
            let app = ReaderApp(support:root)
            let original = Data(contents.utf8)
            try original.write(to:app.stateURL)
            XCTAssertThrowsError(try app.loadLibrary())
            XCTAssertFalse(app.libraryLoaded)
            app.state.preferences.fontSize = 30
            app.windowDidResignKey(Notification(name:NSWindow.didResignKeyNotification))
            app.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification))
            app.persist()
            XCTAssertEqual(try Data(contentsOf:app.stateURL),original)
        }
    }

    @MainActor func testSuccessfulLoadAndFailedBookSwitchPreserveCommittedSession() async throws {
        _ = NSApplication.shared
        let app = ReaderApp(support:root.appendingPathComponent("library"))
        try app.loadLibrary()
        app.window = NSWindow(contentRect:NSRect(x:100,y:100,width:680,height:400),styleMask:[.titled],backing:.buffered,defer:false)
        app.window.isReleasedWhenClosed = false; app.window.contentView = app.normalSurface
        app.mini = StealthWindow(contentRect:NSRect(x:100,y:100,width:360,height:150),styleMask:[.borderless],backing:.buffered,defer:false)
        app.mini.isReleasedWhenClosed = false; app.mini.contentView = app.miniSurface
        defer { app.window.close(); app.mini.close() }
        let a = try makeBook(name:"A",chapters:10), b = try makeBook(name:"B",chapters:2)
        app.state.books = [a,b]
        var errors: [Error] = []; app.errorHandler = { errors.append($0) }
        app.openBook(a,chapter:9); await app.waitForChapterLoad()
        let text = app.currentText, position = app.state.positions[a.id]
        try FileManager.default.removeItem(at:URL(fileURLWithPath:b.directory).appendingPathComponent("chapter0.xhtml"))
        app.openBook(b,chapter:0); await app.waitForChapterLoad()
        XCTAssertEqual(errors.count,1)
        XCTAssertEqual(app.state.selectedBook,a.id)
        XCTAssertEqual(app.displayedBookID,a.id)
        XCTAssertEqual(app.currentChapter,9)
        XCTAssertEqual(app.currentText,text)
        XCTAssertEqual(app.titleLabel.stringValue,"A")
        app.updateProgress(); app.windowDidResignKey(Notification(name:NSWindow.didResignKeyNotification))
        try await app.persistence.flush(app.state).get()
        let saved = try LibraryState.load(from:app.stateURL)
        XCTAssertEqual(saved.selectedBook,a.id)
        XCTAssertEqual(saved.positions[a.id],position)
        XCTAssertNil(saved.positions[b.id])
        app.table.dataSource = app; app.search.stringValue = "章节 2"; app.filterChapters()
        XCTAssertEqual(app.filtered,[1]); XCTAssertEqual(app.table.selectedRow,0)
    }

    func testModifiedArrowKeysUseNativeTextSelection() {
        _ = NSApplication.shared
        let text = ReadingTextView(frame:NSRect(x:0,y:0,width:240,height:100))
        text.string = "Original synthetic text"; text.isEditable = false; text.isSelectable = true
        text.setSelectedRange(NSRange(location:3,length:0))
        var turns: [Int] = []; text.turnPage = { turns.append($0) }
        func key(_ code:UInt16,_ modifiers:NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!
        }
        text.keyDown(with:key(124,.shift))
        XCTAssertTrue(turns.isEmpty)
        text.keyDown(with:key(124,[])); text.keyDown(with:key(49,.shift))
        XCTAssertEqual(turns,[1,-1])
    }

    @MainActor func testNavigationFocusPanelClosingAndHoverLifecycle() throws {
        _ = NSApplication.shared
        let app = ReaderApp(support:root)
        app.window = NSWindow(contentRect:NSRect(x:100,y:100,width:400,height:240),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        app.window.isReleasedWhenClosed = false; app.window.contentView = app.normalSurface
        app.mini = StealthWindow(contentRect:NSRect(x:100,y:100,width:240,height:130),styleMask:[.borderless],backing:.buffered,defer:false)
        app.mini.isReleasedWhenClosed = false; app.mini.contentView = app.miniSurface
        let settings = NSPanel(contentRect:NSRect(x:100,y:100,width:336,height:347),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        settings.isReleasedWhenClosed = false; app.settings = settings
        defer { app.window.close(); app.mini.close(); settings.close(); app.miniSurface.interaction.setHoverTracking(false) }
        app.window.orderFront(nil)
        app.window.makeFirstResponder(app.active.text)
        XCTAssertTrue(app.acceptsPageKeys(in:app.window))
        XCTAssertFalse(app.acceptsPageKeys(in:nil))
        let field = NSSearchField(frame:NSRect(x:0,y:0,width:160,height:24))
        app.normalSurface.addSubview(field); app.window.makeFirstResponder(field)
        XCTAssertFalse(app.acceptsPageKeys(in:app.window))
        let next = NSMenuItem(title:"Next",action:#selector(ReaderApp.nextPage),keyEquivalent:String(UnicodeScalar(NSRightArrowFunctionKey)!))
        XCTAssertFalse(app.validateMenuItem(next))
        settings.orderFront(nil)
        XCTAssertFalse(app.acceptsPageKeys(in:settings))
        app.closeReaderWindow(settings)
        XCTAssertFalse(settings.isVisible); XCTAssertTrue(app.window.isVisible)
        XCTAssertFalse(app.normalSurface.interaction.isHoverTracking)
        app.isStealth = true; app.mini.orderFront(nil); app.syncHoverToolbar()
        XCTAssertTrue(app.miniSurface.interaction.isHoverTracking)
        app.miniSurface.setVisualHidden(true); app.syncHoverToolbar()
        XCTAssertTrue(app.miniSurface.interaction.isHoverTracking,"Concealed transparent content must remain recoverable by double-click")
        app.hideReader()
        XCTAssertFalse(app.miniSurface.interaction.isHoverTracking)
    }

    @MainActor func testSettingsTargetAndControlsFitTheirPanel() throws {
        _ = NSApplication.shared
        let app = ReaderApp(support:root)
        let panel = NSPanel(contentRect:NSRect(x:100,y:100,width:336,height:347),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed = false; app.settings = panel
        defer { panel.close() }
        func descendants(_ view:NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        for tab in [0,1] {
            app.settingsTab = tab
            for section in 0...3 {
                app.settingsSection = section; app.rebuildSettings(); panel.orderFrontRegardless()
                panel.contentView!.layoutSubtreeIfNeeded(); panel.displayIfNeeded()
                let root = panel.contentView!, views = descendants(root)
                if section == 0 {
                    let title = tab == 0 ? "正常阅读排版" : "摸鱼小窗排版"
                    XCTAssertTrue(views.contains { ($0 as? NSTextField)?.stringValue == title })
                }
                for slider in views.compactMap({ $0 as? NSSlider }) {
                    XCTAssertTrue(root.bounds.contains(slider.convert(slider.bounds,to:root)))
                }
                if let output = ProcessInfo.processInfo.environment["MOREAD_VERIFY_UI_OUTPUT"] {
                    let directory = URL(fileURLWithPath:output)
                    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                    let bitmap = root.bitmapImageRepForCachingDisplay(in:root.bounds)!
                    root.cacheDisplay(in:root.bounds,to:bitmap)
                    try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("settings-\(tab)-\(section).png"))
                }
            }
        }
    }

    private func makeBook(name:String,chapters:Int) throws -> Book {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at:directory.appendingPathComponent("META-INF"),withIntermediateDirectories:true)
        try "<container><rootfiles><rootfile full-path='book.opf'/></rootfiles></container>".write(to:directory.appendingPathComponent("META-INF/container.xml"),atomically:true,encoding:.utf8)
        let manifest = (0..<chapters).map { "<item id='c\($0)' href='chapter\($0).xhtml' media-type='application/xhtml+xml'/>" }.joined()
        let spine = (0..<chapters).map { "<itemref idref='c\($0)'/>" }.joined()
        try "<package><metadata><title>\(name)</title></metadata><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>".write(to:directory.appendingPathComponent("book.opf"),atomically:true,encoding:.utf8)
        for index in 0..<chapters {
            try "<html><body><p>\(name) chapter \(index): original synthetic text.</p></body></html>".write(to:directory.appendingPathComponent("chapter\(index).xhtml"),atomically:true,encoding:.utf8)
        }
        return try EPUB.load(directory:directory)
    }
}
