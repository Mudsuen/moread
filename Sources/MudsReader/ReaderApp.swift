import AppKit
import UniformTypeIdentifiers
import ReaderCore

@MainActor final class ReaderApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    var window: NSWindow!
    var mini: StealthWindow!
    let normalSurface = ReaderSurface(frame: .zero), miniSurface = ReaderSurface(frame: .zero)
    let table = ChapterTable(), search = NSSearchField(), bookPicker = NSPopUpButton()
    let titleLabel = NSTextField(labelWithString: "moread"), subtitleLabel = NSTextField(labelWithString: "本地阅读 · 自在留白")
    let progressLabel = NSTextField(labelWithString: ""), chapterLabel = NSTextField(labelWithString: "")
    var state = LibraryState(), currentChapter = 0, currentText = "", filtered: [Int] = []
    var isStealth = false, importing = false, rendering = false
    var restoringWindows = true
    var settings: NSPanel?, statusItem: NSStatusItem!, saveWork: DispatchWorkItem?
    let support: URL
    private(set) var libraryLoaded = false
    private(set) var displayedBookID: String?
    let persistence: LibraryPersistence
    let chapterLoader: @Sendable (Book, Int) throws -> String
    let bookImporter: @Sendable (URL, URL) throws -> (book: Book, text: String)
    var errorHandler: ((Error) -> Void)?
    var terminationReply: ((Bool) -> Void)?
    var terminating = false
    var chapterGeneration: UInt64 = 0, readingIntentGeneration: UInt64 = 0
    var requestedChapter: ChapterLoadRequest?, pendingChapter: ChapterLoadRequest?
    var chapterTask: Task<Void, Never>?, chapterReadTask: Task<Result<String, Error>, Never>?
    var importBatches: [ImportBatch] = []
    var importTask: Task<Void, Never>?
    var importsReady = false

    var stateURL: URL { support.appendingPathComponent("library.json") }
    var book: Book? { state.books.first { $0.id == state.selectedBook } }
    var active: ReaderSurface { isStealth ? miniSurface : normalSurface }
    var canNavigateReader: Bool { !NSApp.isHidden && (isStealth ? mini : window)?.isVisible == true && !active.visuallyHidden }
    var readerHasKeyboardFocus: Bool { acceptsPageKeys(in:NSApp.keyWindow) }
    func acceptsPageKeys(in keyWindow:NSWindow?) -> Bool {
        canNavigateReader && keyWindow === (isStealth ? mini : window) && keyWindow?.firstResponder === active.text
    }
    var settingsValues: [Int:NSTextField] = [:]
    var settingsSliders: [Int:NSSlider] = [:]
    var contentPanel: NSView!
    var settingsTab = 0
    var settingsSection = 0
    let normalDim = DimmingOverlay()
    let contrast = BackgroundContrast()
    let visibilityShortcut = ArrowVisibilityShortcut()
    var adaptiveStatusLabel: NSTextField?
    var permissionButton: NSButton?
    var lastBackgroundSample: BackgroundSample?
    var sidebarWidth: NSLayoutConstraint?
    var hoverToolbar: HoverToolbar?
    var chapterPicker: ChapterPicker?
    var appearanceObserver: NSObjectProtocol?
    var dark: Bool { state.preferences.theme == "dark" || (state.preferences.theme == "system" && NSApp.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua) }
    override convenience init() {
        self.init(support: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MudsReader"))
    }
    init(support: URL,
         chapterLoader: @escaping @Sendable (Book, Int) throws -> String = { try $0.text(at: $1) },
         bookImporter: @escaping @Sendable (URL, URL) throws -> (book: Book, text: String) = { try EPUB.importBookWithOpeningText(from: $0, library: $1) },
         libraryWriter: @escaping LibraryPersistence.Writer = { try $0.save(to: $1) }) {
        self.support = support
        self.chapterLoader = chapterLoader; self.bookImporter = bookImporter
        self.persistence = LibraryPersistence(url: support.appendingPathComponent("library.json"), writer: libraryWriter)
        super.init()
        persistence.onError = { [weak self] in self?.showError($0) }
        contrast.onSample = { [weak self] sample in self?.lastBackgroundSample = sample; self?.applyContrast() }
        contrast.onStatus = { [weak self] status in
            // A transient screenshot failure must not replace a correct color with the
            // theme color (white-on-white in dark mode). Keep the last valid sample.
            if status == .idle || status == .needsPermission {
                self?.lastBackgroundSample = nil; self?.miniSurface.applyBackgroundSample(nil); self?.miniSurface.applyAdaptiveColor(nil)
            }
            self?.refreshContrastStatus()
        }
    }
    func loadLibrary() throws {
        libraryLoaded = false
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let loaded = FileManager.default.fileExists(atPath: stateURL.path) ? try LibraryState.load(from: stateURL) : LibraryState()
        state = loaded
        if FileManager.default.fileExists(atPath: stateURL.path) { persistence.setBaseline(loaded) }
        libraryLoaded = true
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try loadLibrary() }
        catch { rejectPendingImports(); showError(error); NSApp.terminate(nil); return }
        applyAppearance(); buildMenus(); buildWindow(); buildMini(); applyAppearance(); restoringWindows = false; refreshLibrary()
        isStealth = UserDefaults.standard.bool(forKey:"StealthMode")
        appearanceObserver = DistributedNotificationCenter.default().addObserver(forName:NSNotification.Name("AppleInterfaceThemeChangedNotification"),object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.applyAppearance(); self.render(character:self.active.visibleCharacter()); self.refreshVisibleSettings(structureChanged: true)
            }
        }
        if let book {
            let position = state.positions[book.id] ?? ReadingPosition()
            openBook(book, chapter: min(position.chapter,book.chapters.count-1), position: position, userInitiated: false)
        }
        revealReader(highlight: true, userInitiated: false)
        importsReady = true; startPendingImports()
        visibilityShortcut.toggle = { [weak self] in
            guard let self else { return }
            let target = self.isStealth ? self.mini : self.window
            if target?.isVisible == true && !self.active.visuallyHidden { self.hideReader() }
            else { self.revealReader(highlight:false) }
        }
        visibilityShortcut.isEnabled = { [weak self] in self?.interactionOption("ArrowVisibilityEnabled") ?? false }
        visibilityShortcut.canNavigate = { [weak self] in self?.readerHasKeyboardFocus ?? false }
        visibilityShortcut.start()
        if let i = CommandLine.arguments.firstIndex(of: "--import"), CommandLine.arguments.count > i+1 { importURL(URL(fileURLWithPath: CommandLine.arguments[i+1])) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showReader(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard libraryLoaded else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true; invalidateReadingIntent(); recordPosition(); saveWork?.cancel()
        Task { [self] in
            await importTask?.value
            while true {
                recordPosition()
                let snapshot = state
                if case .failure(let error) = await persistence.flush(snapshot, retryFailed: true) {
                    terminating = false; showError(error); replyToTermination(false); return
                }
                if snapshot == state { replyToTermination(true); return }
            }
        }
        return .terminateLater
    }
    func replyToTermination(_ accepted: Bool) { if let terminationReply { terminationReply(accepted) } else { NSApp.reply(toApplicationShouldTerminate: accepted) } }
    func applicationWillTerminate(_ notification: Notification) { visibilityShortcut.stop(); hoverToolbar?.stop(); chapterPicker?.close(); contrast.stop(); invalidateReadingIntent() }
    func windowWillClose(_ notification: Notification) {
        if let closed = notification.object as? NSWindow, closed === window || closed === mini { invalidateReadingIntent() }
        recordPosition(); persist()
    }
    func windowDidMove(_ notification:Notification) { if !restoringWindows, (notification.object as? NSWindow) === mini { mini.saveFrame(usingName:"StealthReaderWindow"); syncContrast(); syncHoverToolbar() } }
    func windowDidResize(_ notification:Notification) { if !restoringWindows, (notification.object as? NSWindow) === mini { mini.saveFrame(usingName:"StealthReaderWindow"); syncContrast(); syncHoverToolbar() }; updateProgress() }
    func applicationDidHide(_ notification:Notification) { invalidateReadingIntent(); contrast.stop(); hoverToolbar?.stop(); miniSurface.interaction.setHoverTracking(false); chapterPicker?.close() }
    func applicationDidUnhide(_ notification:Notification) { syncContrast(); syncHoverToolbar() }
    func windowDidResignKey(_ notification: Notification) { recordPosition(); persist() }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        importURLs(filenames.map { URL(fileURLWithPath: $0) }) { succeeded in sender.reply(toOpenOrPrint: succeeded ? .success : .failure) }
    }
    func makeItem(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; item.keyEquivalentModifierMask = modifiers; return item
    }
    func buildMenus() {
        let main = NSMenu()
        let appMenu = NSMenu(); appMenu.addItem(makeItem("关于moread",#selector(about))); appMenu.addItem(.separator())
        appMenu.addItem(makeItem("阅读设置…",#selector(showSettings),key:",")); appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title:"隐藏moread",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")); appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title:"退出moread",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"))
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)
        let fileMenu = NSMenu(title:"文件"); fileMenu.addItem(makeItem("导入 EPUB…",#selector(importBook),key:"o")); fileMenu.addItem(makeItem("从 Apple Books 导入…",#selector(importFromBooks))); fileMenu.addItem(.separator()); fileMenu.addItem(makeItem("显示阅读器",#selector(showReader))); fileMenu.addItem(makeItem("关闭窗口",#selector(closeWindow),key:"w"))
        let file = NSMenuItem(); file.submenu = fileMenu; main.addItem(file)
        let editMenu = NSMenu(title:"编辑")
        for (title,action,key) in [("剪切",#selector(NSText.cut(_:)),"x"),("复制",#selector(NSText.copy(_:)),"c"),("粘贴",#selector(NSText.paste(_:)),"v"),("全选",#selector(NSText.selectAll(_:)),"a")] {
            editMenu.addItem(NSMenuItem(title:title,action:action,keyEquivalent:key))
        }
        let edit = NSMenuItem(); edit.submenu = editMenu; main.addItem(edit)
        let reading = NSMenu(title:"阅读"); reading.addItem(makeItem("切换摸鱼模式",#selector(toggleStealth),key:"m",modifiers:[.command,.shift])); reading.addItem(makeItem("上一页",#selector(previousPage),key:String(UnicodeScalar(NSLeftArrowFunctionKey)!),modifiers:[])); reading.addItem(makeItem("下一页",#selector(nextPage),key:String(UnicodeScalar(NSRightArrowFunctionKey)!),modifiers:[])); reading.addItem(.separator()); reading.addItem(makeItem("上一章",#selector(previousChapter),key:"[")); reading.addItem(makeItem("下一章",#selector(nextChapter),key:"]")); reading.addItem(makeItem("搜索目录",#selector(focusSearch),key:"f")); reading.addItem(.separator()); reading.addItem(makeItem("放大文字",#selector(larger),key:"=")); reading.addItem(makeItem("缩小文字",#selector(smaller),key:"-"))
        let plus = makeItem("放大文字",#selector(larger),key:"+"); plus.isHidden = true; plus.allowsKeyEquivalentWhenHidden = true; reading.addItem(plus)
        reading.addItem(.separator())
        reading.addItem(makeItem("切换翻页 / 滚动",#selector(toggleReadingMode),key:"p",modifiers:[.command,.shift]))
        reading.addItem(makeItem("提高亮度",#selector(brighter),key:String(UnicodeScalar(NSUpArrowFunctionKey)!),modifiers:[.command,.option]))
        reading.addItem(makeItem("降低亮度",#selector(dimmer),key:String(UnicodeScalar(NSDownArrowFunctionKey)!),modifiers:[.command,.option]))
        reading.addItem(makeItem("小窗更透明",#selector(moreTransparent),key:String(UnicodeScalar(NSRightArrowFunctionKey)!),modifiers:[.command,.option]))
        reading.addItem(makeItem("小窗更不透明",#selector(lessTransparent),key:String(UnicodeScalar(NSLeftArrowFunctionKey)!),modifiers:[.command,.option]))
        let read = NSMenuItem(); read.submenu = reading; main.addItem(read); NSApp.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName:"book.closed",accessibilityDescription:"moread")
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on:[.leftMouseUp,.rightMouseUp])
    }
    @objc func statusItemClicked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp, let button = statusItem.button {
            NSMenu.popUpContextMenu(contextMenu(),with:event,for:button)
        } else { showReader() }
    }
    func contextMenu() -> NSMenu {
        let menu = NSMenu(); menu.addItem(makeItem("显示阅读器",#selector(showReader))); if contrast.status == .needsPermission { menu.addItem(makeItem("自动文字需要屏幕授权…",#selector(requestScreenPermission))) }; menu.addItem(makeItem("切换摸鱼模式 ⇧⌘M",#selector(toggleStealth))); menu.addItem(makeItem("阅读设置… ⌘,",#selector(showSettings))); menu.addItem(.separator()); menu.addItem(makeItem("上一章",#selector(previousChapter))); menu.addItem(makeItem("下一章",#selector(nextChapter))); menu.addItem(.separator()); menu.addItem(makeItem("隐藏窗口 Esc",#selector(hideReader))); return menu
    }
    func button(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let b = NSButton(image:NSImage(systemSymbolName:symbol,accessibilityDescription:label)!,target:self,action:action)
        b.contentTintColor = .secondaryLabelColor; b.bezelStyle = .texturedRounded; b.isBordered = false; b.toolTip = label; b.setAccessibilityLabel(label)
        b.translatesAutoresizingMaskIntoConstraints = false; b.widthAnchor.constraint(equalToConstant:32).isActive = true; b.heightAnchor.constraint(equalToConstant:30).isActive = true
        return b
    }
    func buildWindow() {
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1020,height:740),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title = "moread"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.minSize = NSSize(width:720,height:460); window.isReleasedWhenClosed = false; window.delegate = self
        window.setFrameAutosaveName("MainReaderWindow"); if !window.setFrameUsingName("MainReaderWindow") { window.center() }
        let root = NSView(); root.wantsLayer = true; root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor; window.contentView = root
        let sidebar = NSVisualEffectView(); sidebar.material = .sidebar; sidebar.blendingMode = .behindWindow; sidebar.state = .active
        let content = NSView(); contentPanel = content; content.wantsLayer = true; content.layer?.backgroundColor = pageColor.cgColor
        for view in [sidebar,content] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([sidebar.widthAnchor.constraint(equalToConstant:238),sidebar.topAnchor.constraint(equalTo:root.topAnchor),sidebar.bottomAnchor.constraint(equalTo:root.bottomAnchor),content.leadingAnchor.constraint(equalTo:sidebar.trailingAnchor),content.trailingAnchor.constraint(equalTo:root.trailingAnchor),content.topAnchor.constraint(equalTo:root.topAnchor),content.bottomAnchor.constraint(equalTo:root.bottomAnchor)])
        sidebarWidth = sidebar.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:UserDefaults.standard.bool(forKey:"SidebarVisible") ? 0 : -238); sidebarWidth?.isActive = true
        sidebar.clipsToBounds = true
        let brand = NSTextField(labelWithString:"moread"); brand.font = .systemFont(ofSize:18,weight:.semibold)
        let local = NSTextField(labelWithString:"我的书架"); local.font = .systemFont(ofSize:11,weight:.medium); local.textColor = .secondaryLabelColor
        bookPicker.target = self; bookPicker.action = #selector(selectBook); bookPicker.setAccessibilityLabel("我的书架")
        search.placeholderString = "搜索章节"; search.focusRingType = .none; search.delegate = self; search.setAccessibilityLabel("搜索章节")
        let importButton = NSButton(title:"导入书籍",image:NSImage(systemSymbolName:"plus",accessibilityDescription:nil)!,target:self,action:#selector(importBook)); importButton.bezelStyle = .rounded
        let tableScroll = NSScrollView(); tableScroll.documentView = table; tableScroll.hasVerticalScroller = true; tableScroll.autohidesScrollers = true; tableScroll.drawsBackground = false
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("chapter")); column.width = 207; table.addTableColumn(column); table.headerView = nil; table.backgroundColor = .clear; table.rowHeight = 35; table.style = .sourceList; table.delegate = self; table.dataSource = self; table.target = self; table.action = #selector(selectChapter); table.setAccessibilityLabel("章节目录")
        for v in [brand,local,bookPicker,search,tableScroll,importButton] { v.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(v) }
        NSLayoutConstraint.activate([brand.topAnchor.constraint(equalTo:sidebar.topAnchor,constant:52),brand.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:22),local.topAnchor.constraint(equalTo:brand.bottomAnchor,constant:23),local.leadingAnchor.constraint(equalTo:brand.leadingAnchor),bookPicker.topAnchor.constraint(equalTo:local.bottomAnchor,constant:8),bookPicker.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:16),bookPicker.trailingAnchor.constraint(equalTo:sidebar.trailingAnchor,constant:-16),search.topAnchor.constraint(equalTo:bookPicker.bottomAnchor,constant:18),search.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:18),search.trailingAnchor.constraint(equalTo:sidebar.trailingAnchor,constant:-18),tableScroll.topAnchor.constraint(equalTo:search.bottomAnchor,constant:14),tableScroll.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:8),tableScroll.trailingAnchor.constraint(equalTo:sidebar.trailingAnchor,constant:-8),tableScroll.bottomAnchor.constraint(equalTo:importButton.topAnchor,constant:-14),importButton.bottomAnchor.constraint(equalTo:sidebar.bottomAnchor,constant:-18),importButton.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:18),importButton.trailingAnchor.constraint(equalTo:sidebar.trailingAnchor,constant:-18)])
        titleLabel.font = .systemFont(ofSize:15,weight:.medium); titleLabel.textColor = .labelColor
        subtitleLabel.font = .systemFont(ofSize:11); subtitleLabel.textColor = .secondaryLabelColor
        chapterLabel.font = .systemFont(ofSize:12,weight:.medium); chapterLabel.textColor = .secondaryLabelColor; chapterLabel.lineBreakMode = .byTruncatingTail
        progressLabel.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular); progressLabel.textColor = .secondaryLabelColor
        table.activateSelection = { [weak self] in self?.selectChapter() }
        let sidebarToggle = button("sidebar.left","书架与目录",#selector(toggleSidebar)), mode = button("rectangle.compress.vertical","摸鱼模式 ⇧⌘M",#selector(toggleStealth)), settings = button("textformat.size","阅读设置 ⌘,",#selector(showSettings)), prev = button("chevron.left","上一页 ←",#selector(previousPage)), next = button("chevron.right","下一页 →",#selector(nextPage))
        let line = NSBox(); line.boxType = .separator
        for v in [titleLabel,subtitleLabel,chapterLabel,progressLabel,sidebarToggle,mode,settings,prev,next,line,normalSurface] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([sidebarToggle.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:20),sidebarToggle.centerYAnchor.constraint(equalTo:titleLabel.centerYAnchor),titleLabel.centerXAnchor.constraint(equalTo:content.centerXAnchor),titleLabel.topAnchor.constraint(equalTo:content.topAnchor,constant:28),titleLabel.trailingAnchor.constraint(lessThanOrEqualTo:settings.leadingAnchor,constant:-16),subtitleLabel.centerXAnchor.constraint(equalTo:titleLabel.centerXAnchor),subtitleLabel.topAnchor.constraint(equalTo:titleLabel.bottomAnchor,constant:7),mode.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-32),mode.centerYAnchor.constraint(equalTo:titleLabel.centerYAnchor),settings.trailingAnchor.constraint(equalTo:mode.leadingAnchor,constant:-9),settings.centerYAnchor.constraint(equalTo:mode.centerYAnchor),line.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:52),line.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-52),line.topAnchor.constraint(equalTo:subtitleLabel.bottomAnchor,constant:14),normalSurface.topAnchor.constraint(equalTo:line.bottomAnchor,constant:3),normalSurface.leadingAnchor.constraint(equalTo:content.leadingAnchor),normalSurface.trailingAnchor.constraint(equalTo:content.trailingAnchor),normalSurface.bottomAnchor.constraint(equalTo:chapterLabel.topAnchor,constant:-16),chapterLabel.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:52),chapterLabel.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-23),chapterLabel.trailingAnchor.constraint(lessThanOrEqualTo:progressLabel.leadingAnchor,constant:-16),next.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-27),next.centerYAnchor.constraint(equalTo:chapterLabel.centerYAnchor),prev.trailingAnchor.constraint(equalTo:next.leadingAnchor,constant:-2),prev.centerYAnchor.constraint(equalTo:next.centerYAnchor),progressLabel.trailingAnchor.constraint(equalTo:prev.leadingAnchor,constant:-16),progressLabel.centerYAnchor.constraint(equalTo:chapterLabel.centerYAnchor)])
        configure(normalSurface)
        normalDim.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(normalDim)
        normalDim.setAccessibilityElement(false)
        NSLayoutConstraint.activate([normalDim.leadingAnchor.constraint(equalTo:root.leadingAnchor),normalDim.trailingAnchor.constraint(equalTo:root.trailingAnchor),normalDim.topAnchor.constraint(equalTo:root.topAnchor),normalDim.bottomAnchor.constraint(equalTo:root.bottomAnchor)])
    }
    @objc func toggleSidebar() {
        let show = (sidebarWidth?.constant ?? -238) != 0
        sidebarWidth?.constant = show ? 0 : -238; UserDefaults.standard.set(show,forKey:"SidebarVisible")
        window.contentView?.layoutSubtreeIfNeeded()
    }
    func buildMini() {
        mini = StealthWindow(contentRect:NSRect(x:0,y:0,width:360,height:150),styleMask:[.borderless],backing:.buffered,defer:false)
        mini.title = "moread · 摸鱼"; mini.minSize = NSSize(width:160,height:64); mini.isReleasedWhenClosed = false; mini.delegate = self
        mini.hasShadow = false; mini.isOpaque = false; mini.backgroundColor = .clear
        mini.level = state.preferences.floating ? .floating : .normal
        mini.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        mini.contentView = miniSurface; mini.setFrameAutosaveName("StealthReaderWindow"); if !mini.restoreSavedGeometry(named:"StealthReaderWindow") { mini.center() }; configure(miniSurface); miniSurface.toggleVisualVisibility = { [weak self] in
            guard let self, self.interactionOption("DoubleClickVisibilityEnabled") else { return }; self.toggleVisualHidden()
        }
        hoverToolbar = HoverToolbar(reader:mini)
        hoverToolbar?.textTop = { [weak self] in self?.miniSurface.visibleTextTopOnScreen() }
        hoverToolbar?.onContents = { [weak self] in self?.showChapterPicker() }
        hoverToolbar?.onSettings = { [weak self] in self?.showSettings() }
        hoverToolbar?.onPin = { [weak self] in self?.togglePin() }
    }
    func configure(_ surface: ReaderSurface) {
        surface.scroll.canNavigate = { [weak self] in self?.canNavigateReader ?? false }
        surface.text.turnPage = { [weak self] in self?.turnPage($0) }
        surface.text.hideReader = { [weak self] in self?.hideReader() }
        surface.text.menu = contextMenu()
        surface.didScroll = { [weak self] in guard let self, !self.rendering else { return }; self.recordPosition(); self.updateProgress(); self.scheduleSave() }
    }
    func refreshLibrary() {
        bookPicker.removeAllItems()
        if state.books.isEmpty { bookPicker.addItem(withTitle:"尚未导入书籍"); bookPicker.isEnabled = false }
        else {
            bookPicker.isEnabled = true
            let menu = NSMenu(); menu.autoenablesItems = false
            for book in state.books { let item = NSMenuItem(title: book.title, action: nil, keyEquivalent: ""); item.representedObject = book.id; menu.addItem(item) }
            bookPicker.menu = menu
            if let item = menu.items.first(where: { ($0.representedObject as? String) == state.selectedBook }) { bookPicker.select(item) }
        }
        titleLabel.stringValue = book?.title ?? "留一点时间，给阅读"
        subtitleLabel.stringValue = book.map { "\($0.author)  ·  \($0.chapters.count) 节" } ?? "导入一本 EPUB，开始阅读"
        filterChapters()
    }
    func tableView(_ tableView:NSTableView,rowViewForRow row:Int) -> NSTableRowView? { ReaderRowView() }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let book, filtered.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("ChapterCell")
        let cell = (tableView.makeView(withIdentifier:id,owner:self) as? NSTableCellView) ?? NSTableCellView()
        if cell.textField == nil {
            cell.identifier = id; let field = NSTextField(labelWithString:""); field.font = .systemFont(ofSize:12); field.lineBreakMode = .byTruncatingTail; field.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(field); cell.textField = field
            NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:8),field.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-6),field.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
        }
        cell.textField?.textColor = .labelColor; cell.textField?.stringValue = book.chapters[filtered[row]].title; cell.toolTip = cell.textField?.stringValue
        return cell
    }
    func controlTextDidChange(_ obj: Notification) { filterChapters() }
    func control(_ control:NSControl,textView:NSTextView,doCommandBy commandSelector:Selector) -> Bool {
        guard control === search else { return false }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            if table.selectedRow < 0, !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false) }
            window.makeFirstResponder(table); return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { selectChapter(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { window.makeFirstResponder(active.text); return true }
        return false
    }
    func filterChapters() {
        let query = search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        let chapters = book?.chapters ?? []
        filtered = chapters.indices.filter { query.isEmpty || chapters[$0].title.localizedCaseInsensitiveContains(query) }
        table.reloadData(); selectCurrentRow()
    }
    func selectCurrentRow() {
        guard !filtered.isEmpty else { table.deselectAll(nil); return }
        let row = filtered.firstIndex(of:currentChapter) ?? 0
        table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); table.scrollRowToVisible(row)
    }
    @objc func selectChapter() { guard filtered.indices.contains(table.selectedRow) else { return }; openChapter(filtered[table.selectedRow]) }
    @objc func selectBook() {
        guard let id = bookPicker.selectedItem?.representedObject as? String,
              let target = state.books.first(where: { $0.id == id }) else { return }
        let position = state.positions[target.id] ?? ReadingPosition()
        openBook(target, chapter: position.chapter, position: position)
    }
    func commitChapter(book target:Book,chapter:Int,text:String,character:Int = 0,end:Bool = false,legacyCharacter:Int? = nil,legacyChapter:Int? = nil,migrated:Bool = false,save:Bool = true) {
        recordPosition()
        let changedBook = displayedBookID != target.id
        rendering = true
        state.selectedBook = target.id; displayedBookID = target.id
        currentChapter = chapter; currentText = text.isEmpty ? "本节没有文字内容" : text
        if changedBook { chapterPicker?.close(); refreshLibrary() } else { selectCurrentRow() }
        render(character:character); if end { active.goToEnd() }
        state.positions[target.id] = ReadingPosition(chapter:chapter,character:active.visibleCharacter(),legacyCharacter:legacyCharacter ?? state.positions[target.id]?.legacyCharacter,legacyChapter:legacyChapter ?? state.positions[target.id]?.legacyChapter)
        rendering = false; recordPosition(); updateProgress(); if save { persist() }
        if migrated { subtitleLabel.stringValue = "正文排版已更新 · 已保留章节，从章首继续" }
        if (isStealth ? mini : window)?.isVisible == true, !active.visuallyHidden, !NSApp.isHidden { (isStealth ? mini : window)?.makeFirstResponder(active.text) }
    }
    func openChapter(_ chapter: Int, character: Int = 0, end: Bool = false) {
        guard let target = book, target.chapters.indices.contains(chapter) else { return }
        openBook(target, chapter: chapter, character: character, end: end)
    }
    func render(character: Int) {
        let p = state.preferences
        // Ensure even the largest small-window typography can fit one complete line.
        if isStealth {
            let minHeight = max(64,ceil(p.stealthFontSize*2.1*p.stealthLineHeight+14+p.stealthParagraphSpacing))
            mini.minSize = NSSize(width:160,height:minHeight)
            if mini.frame.height < minHeight {
                var frame = mini.frame; frame.origin.y -= minHeight-frame.height; frame.size.height = minHeight; mini.setFrame(frame,display:true)
            }
        }
        active.display(currentText,fontSize:isStealth ? p.stealthFontSize : p.fontSize,brightness:p.brightness,stealth:isStealth,character:character,dark:dark,fontName:isStealth ? p.stealthFontName : p.fontName,lineHeight:isStealth ? p.stealthLineHeight : p.lineHeight,paragraphSpacing:isStealth ? p.stealthParagraphSpacing : p.paragraphSpacing,margin:p.margin,mode:p.readingMode,backgroundOpacity:p.opacity,textOpacity:p.textOpacity,adaptiveText:p.adaptiveText)
        contentPanel?.layer?.backgroundColor = pageColor.cgColor
        mini.alphaValue = 1; mini.level = p.floating ? .floating : .normal
        normalDim.brightness = p.brightness
        applyContrast(); syncContrast(); syncHoverToolbar(); updateProgress()
    }
    func syncHoverToolbar() {
        guard mini != nil else { return }
        miniSurface.interaction.setHoverTracking(isStealth && mini.isVisible && !NSApp.isHidden)
        hoverToolbar?.update(enabled:isStealth && mini.isVisible && !miniSurface.visuallyHidden && !NSApp.isHidden,pinned:state.preferences.floating,tint:miniSurface.foregroundColor,fontSize:state.preferences.stealthFontSize)
    }
    @objc func showChapterPicker() {
        guard let book, let screen = mini.screen else { return }
        if chapterPicker == nil { chapterPicker = ChapterPicker() }
        let presentedBookID = book.id
        chapterPicker?.onSelect = { [weak self] index in
            guard let self, self.displayedBookID == presentedBookID,
                  self.requestedChapter == nil || self.requestedChapter?.book.id == presentedBookID else { return }
            self.openChapter(index); self.mini.makeKeyAndOrderFront(nil)
        }
        let anchor = hoverToolbar?.panel.isVisible == true ? hoverToolbar!.panel.frame : mini.frame
        chapterPicker?.present(book:book,chapter:currentChapter,near:anchor,screen:screen.visibleFrame)
    }
    func syncContrast() {
        guard mini != nil else { return }
        contrast.update(window:mini,enabled:isStealth && !miniSurface.visuallyHidden && state.preferences.adaptiveText && state.preferences.opacity < 1)
    }
    func applyContrast() {
        let p = state.preferences
        guard p.adaptiveText, p.opacity < 1, let sample = lastBackgroundSample, contrast.status != .needsPermission else { miniSurface.applyBackgroundSample(nil); miniSurface.applyAdaptiveColor(nil); return }
        miniSurface.applyBackgroundSample(sample); syncHoverToolbar(); refreshContrastStatus()
    }
    func refreshContrastStatus() {
        statusItem?.button?.toolTip = contrast.status == .needsPermission ? "moread：自动文字需要屏幕读取权限" : "moread · 点击显示，右键打开菜单"
        switch contrast.status {
        case .idle: adaptiveStatusLabel?.stringValue = "透明小窗显示时启用"
        case .needsPermission: adaptiveStatusLabel?.stringValue = "需要屏幕读取权限"
        case .active: adaptiveStatusLabel?.stringValue = "根据文字下方背景调整"
        case .unavailable: adaptiveStatusLabel?.stringValue = "暂时无法读取背景"
        }
        permissionButton?.isHidden = contrast.status == .active || contrast.status == .idle
    }
    @objc func requestScreenPermission() { contrast.requestPermission(); syncContrast() }
    @objc func toggleAdaptive(_ sender:NSButton) {
        guard state.preferences.adaptiveText != (sender.state == .on) else { return }
        state.preferences.adaptiveText = sender.state == .on
        if !state.preferences.adaptiveText { lastBackgroundSample = nil; miniSurface.applyBackgroundSample(nil); miniSurface.applyAdaptiveColor(nil) }
        syncContrast(); persist()
    }
    @objc func toggleVisualHidden() {
        guard isStealth else { return }
        invalidateReadingIntent(); recordPosition(); miniSurface.setVisualHidden(!miniSurface.visuallyHidden); if miniSurface.visuallyHidden { visibilityShortcut.cancelPending(); chapterPicker?.close() }; syncContrast(); syncHoverToolbar(); persist()
    }
    @objc func togglePin() {
        state.preferences.floating.toggle(); mini.level = state.preferences.floating ? .floating : .normal
        syncHoverToolbar()
        refreshVisibleSettings(); persist()
    }
    func recordPosition() {
        guard !rendering, let book, displayedBookID == book.id else { return }
        state.positions[book.id] = ReadingPosition(chapter:currentChapter,character:active.visibleCharacter(),legacyCharacter:state.positions[book.id]?.legacyCharacter,legacyChapter:state.positions[book.id]?.legacyChapter)
    }
    func updateProgress() {
        guard let book, displayedBookID == book.id else { return }
        chapterLabel.stringValue = book.chapters[currentChapter].title
        let fraction = Double(active.visibleCharacter()) / Double(max(1,(currentText as NSString).length))
        let percent = 100 * (Double(currentChapter)+fraction) / Double(book.chapters.count)
        let page = pModePageLabel
        progressLabel.stringValue = page + String(format:"%d / %d  ·  %.1f%%",currentChapter+1,book.chapters.count,percent)
    }
    var pModePageLabel: String { state.preferences.readingMode == .paged ? "\(active.pageIndex+1)/\(max(1,active.pageRanges.count)) 页  ·  " : "" }
    @objc func toggleReadingMode() { setReadingMode(state.preferences.readingMode == .paged ? .scrolling : .paged) }
    func setReadingMode(_ mode: ReadingMode) {
        guard state.preferences.readingMode != mode else { return }
        let character = active.visibleCharacter(); state.preferences.readingMode = mode
        rendering = true; render(character:character); rendering = false
        recordPosition(); updateProgress(); refreshVisibleSettings(); persist()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if [#selector(previousPage),#selector(nextPage)].contains(menuItem.action), !menuItem.keyEquivalent.isEmpty { return readerHasKeyboardFocus }
        if [#selector(previousPage),#selector(nextPage),#selector(previousChapter),#selector(nextChapter)].contains(menuItem.action) { return canNavigateReader }
        if [#selector(importBook),#selector(importFromBooks)].contains(menuItem.action) { return !terminating }
        if [#selector(moreTransparent),#selector(lessTransparent)].contains(menuItem.action) { return isStealth }
        return true
    }
    @objc func brighter() { adjustMini(brightness:0.05) }
    @objc func dimmer() { adjustMini(brightness:-0.05) }
    @objc func moreTransparent() { adjustMini(transparency:0.05) }
    @objc func lessTransparent() { adjustMini(transparency:-0.05) }
    func adjustMini(brightness:Double = 0,transparency:Double = 0) {
        guard isStealth || transparency == 0 else { return }
        let character = active.visibleCharacter()
        let previous = state.preferences
        if brightness != 0 { state.preferences.adjustBrightness(by:brightness) }
        if transparency != 0 { state.preferences.adjustTransparency(by:transparency) }
        guard state.preferences != previous else { return }
        render(character:character); refreshVisibleSettings(); scheduleSave()
    }
    func scheduleSave() { saveWork?.cancel(); let work = DispatchWorkItem { [weak self] in self?.persist() }; saveWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.35,execute:work) }
    func persist() { saveWork?.cancel(); guard libraryLoaded else { return }; persistence.submit(state) }
    func turnPage(_ direction: Int) {
        guard canNavigateReader, let book = requestedChapter?.book ?? book else { return }
        if requestedChapter != nil || active.page(direction) {
            let next = (requestedChapter?.chapter ?? currentChapter)+direction
            if book.chapters.indices.contains(next) { openBook(book,chapter:next,end:direction < 0) }
        }
    }
    @objc func nextPage() { turnPage(1) }
    @objc func previousPage() { turnPage(-1) }
    @objc func nextChapter() { moveChapter(1) }
    @objc func previousChapter() { moveChapter(-1) }
    func moveChapter(_ delta: Int) {
        guard canNavigateReader, let target = requestedChapter?.book ?? book else { return }
        let chapter = (requestedChapter?.chapter ?? currentChapter) + delta
        guard target.chapters.indices.contains(chapter) else { return }
        openBook(target, chapter: chapter)
    }
    @objc func focusSearch() { if isStealth { showChapterPicker(); return }; if sidebarWidth?.constant != 0 { toggleSidebar() }; window.makeFirstResponder(search) }
    @objc func toggleStealth() {
        guard book != nil else { importBook(); return }
        invalidateReadingIntent(); recordPosition(); let character = state.positions[book!.id]?.character ?? 0
        chapterPicker?.close(); miniSurface.setVisualHidden(false); isStealth.toggle(); UserDefaults.standard.set(isStealth,forKey:"StealthMode"); rendering = true; render(character:character); rendering = false
        if isStealth { window.orderOut(nil); mini.makeKeyAndOrderFront(nil); mini.makeFirstResponder(miniSurface.text) }
        else { mini.orderOut(nil); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(normalSurface.text) }
        updateProgress(); syncContrast(); syncHoverToolbar(); refreshVisibleSettings(); persist(); NSApp.activate(ignoringOtherApps:true)
    }
    @objc func hideReader() { invalidateReadingIntent(); visibilityShortcut.cancelPending(); active.locator.cancel(); hoverToolbar?.stop(); miniSurface.interaction.setHoverTracking(false); chapterPicker?.close(); contrast.stop(); recordPosition(); persist(); (isStealth ? mini : window)?.orderOut(nil); settings?.orderOut(nil) }
    @objc func closeWindow() { closeReaderWindow(NSApp.keyWindow) }
    func closeReaderWindow(_ keyWindow:NSWindow?) {
        if let settings, keyWindow === settings { settings.performClose(nil); return }
        if let chapterPicker, keyWindow === chapterPicker.panel { chapterPicker.close(); return }
        hideReader()
    }
    @objc func showReader() { revealReader(highlight:true) }
    func revealReader(highlight:Bool, userInitiated: Bool = true) {
        if userInitiated { readingIntentGeneration += 1 }
        guard let target = isStealth ? mini : window else { return }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersection(target.frame).width > 40 && $0.visibleFrame.intersection(target.frame).height > 30 }) { target.center() }
        active.setVisualHidden(false)
        target.makeKeyAndOrderFront(nil); target.makeFirstResponder(active.text)
        NSApp.activate(ignoringOtherApps:true); if highlight && interactionOption("RevealHighlightEnabled") { active.locator.pulse() } else { active.locator.cancel() }; syncContrast(); syncHoverToolbar()
    }
    @objc func larger() { changeFont(1) }
    @objc func smaller() { changeFont(-1) }
    func changeFont(_ delta: Double) {
        let anchor = active.visibleCharacter(), previous = state.preferences
        if isStealth { state.preferences.stealthFontSize = min(20,max(8,state.preferences.stealthFontSize+delta)) } else { state.preferences.fontSize = min(32,max(14,state.preferences.fontSize+delta)) }
        guard state.preferences != previous else { return }
        render(character:anchor); refreshVisibleSettings(); scheduleSave()
    }
    @objc func importBook() { openImportPanel(directory:nil) }
    @objc func importFromBooks() { openImportPanel(directory:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/iCloud~com~apple~iBooks/Documents")) }
    func openImportPanel(directory: URL?) {
        let panel = NSOpenPanel(); panel.title = "导入 EPUB"; panel.allowedContentTypes = [.epub]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = true; panel.treatsFilePackagesAsDirectories = false; panel.directoryURL = directory
        panel.begin { [weak self] response in if response == .OK { self?.importURLs(panel.urls) } }
    }
    func importURL(_ url: URL) { importURLs([url]) }
    var pageColor: NSColor { dark ? NSColor.black : NSColor(white:0.97,alpha:1) }
    func applyAppearance() {
        NSApp.appearance = nil
        let appearance: NSAppearance?
        switch state.preferences.theme { case "dark": appearance = NSAppearance(named:.darkAqua); case "light": appearance = NSAppearance(named:.aqua); default: appearance = nil }
        window?.appearance = appearance; mini?.appearance = appearance
    }
    @objc func showSettings() {
        if settings == nil {
            let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:336,height:347),styleMask:[.titled,.closable,.utilityWindow],backing:.buffered,defer:false)
            panel.title = "moread"; panel.titlebarAppearsTransparent = true; panel.isReleasedWhenClosed = false; panel.level = .floating
            settings = panel; settingsTab = isStealth ? 1 : 0; rebuildSettings(); panel.center()
        } else if !(settings?.isVisible ?? false) {
            settingsTab = isStealth ? 1 : 0; rebuildSettings()
        }
        settings?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func rebuildSettings() {
        guard let panel = settings else { return }; settingsValues.removeAll(); settingsSliders.removeAll(); adaptiveStatusLabel = nil; permissionButton = nil
        let top = panel.frame.maxY, height: CGFloat = settingsSection == 3 ? 475 : (settingsSection == 0 ? 347 : (settingsSection == 1 ? 251 : 293))
        panel.setContentSize(NSSize(width:336,height:height)); panel.setFrameOrigin(NSPoint(x:panel.frame.minX,y:top-panel.frame.height))
        let root = NSView(); root.wantsLayer = true; root.layer?.backgroundColor = ReaderPalette.panel.cgColor; panel.contentView = root
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo:root.topAnchor,constant:14),stack.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:14),stack.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-14)])
        func fullWidth(_ view:NSView) { view.widthAnchor.constraint(equalToConstant:308).isActive = true; stack.addArrangedSubview(view) }
        let header = NSStackView(); header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 6; header.distribution = .fill
        let title = NSTextField(labelWithString:settingsSection == 0 ? (settingsTab == 1 ? "摸鱼小窗排版" : "正常阅读排版") : "阅读设置"); title.font = .systemFont(ofSize:14,weight:.semibold); title.setContentHuggingPriority(NSLayoutConstraint.Priority(1),for:.horizontal)
        header.addArrangedSubview(title)
        let themeIcon = state.preferences.theme == "system" ? "circle.lefthalf.filled" : (state.preferences.theme == "dark" ? "moon.fill" : "sun.max.fill")
        for control in [button(themeIcon,"外观：跟随系统 / 亮色 / 暗色",#selector(showThemeMenu(_:))),button(state.preferences.readingMode == .paged ? "book.pages" : "scroll","切换翻页 / 滚动 ⇧⌘P",#selector(toggleReadingMode)),button(isStealth ? "rectangle.expand.vertical" : "rectangle.compress.vertical","切换正常 / 摸鱼 ⇧⌘M",#selector(toggleStealth))] { control.contentTintColor = ReaderPalette.accent; header.addArrangedSubview(control) }
        fullWidth(header)
        let sections = StyledSegment(labels:["排版","外观","小窗","操作"],target:self,action:#selector(settingsSectionChanged(_:))); sections.selectedSegment = settingsSection; sections.setAccessibilityLabel("设置分类"); fullWidth(sections)
        if settingsSection == 3 {
            let options = SettingsCard(frame:.zero); fullWidth(options)
            for (key,title) in [("ArrowVisibilityEnabled","← + → 同时按住：隐藏 / 显示"),("DoubleClickVisibilityEnabled","双击小窗：视觉隐藏 / 恢复"),("RevealHighlightEnabled","图标唤起时显示高亮白边")] {
                let control = MonochromeCheckBox(title:title,target:self,action:#selector(interactionOptionChanged(_:)))
                control.identifier = NSUserInterfaceItemIdentifier(key); control.state = interactionOption(key) ? .on : .off
                control.font = .systemFont(ofSize:11); options.stack.addArrangedSubview(control)
            }
            let note = NSTextField(wrappingLabelWithString:"快捷键唤起不显示白边。左右键需全部松开后再次触发；双击视觉隐藏后可再次双击恢复。")
            note.font = .systemFont(ofSize:10); note.textColor = .secondaryLabelColor; note.widthAnchor.constraint(equalToConstant:284).isActive = true; options.stack.addArrangedSubview(note)
            let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.heightAnchor.constraint(equalToConstant:215).isActive = true; fullWidth(scroll)
            let text = NSTextView(); text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
            text.textContainerInset = NSSize(width:8,height:6); text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true; text.font = .systemFont(ofSize:11); text.textColor = .labelColor
            text.string = "快捷键与恢复方式\n\n← / ↑ / Page Up　上一页\n→ / ↓ / Page Down　下一页\n空格 / ⇧空格　下一页 / 上一页\n⌘[ / ⌘]　上一章 / 下一章\n⌘F　搜索目录\n⌘,　打开设置\n⌘+ / ⌘−　放大 / 缩小字号\n⌥⌘↑ / ↓　提高 / 降低亮度\n⌥⌘→ / ←　增加 / 减少背景透明\n⇧⌘P　翻页 / 滚动\n⇧⌘M　正常阅读 / 摸鱼小窗\nEsc　隐藏阅读器\n⌘W　关闭当前窗口\n\n点击 Dock 图标或左键菜单栏图标可唤起。\n右键菜单栏图标打开菜单。\n指针进入小窗显示目录、设置和置顶按钮。\n拖动正文移动窗口，拖动边缘调整大小。\n\n除左右键组合外，快捷键需 moread 获得焦点。"
            text.setAccessibilityLabel("快捷键与恢复方式"); scroll.documentView = text
            text.frame = NSRect(x:0,y:0,width:308,height:560)
            return
        }
        let card = SettingsCard(frame:.zero); fullWidth(card)
        let p = state.preferences, stealth = settingsTab == 1
        func add(_ view:NSView) { view.widthAnchor.constraint(equalToConstant:284).isActive = true; card.stack.addArrangedSubview(view) }
        func slider(_ tag:Int,_ name:String,_ value:Double,_ low:Double,_ high:Double,_ symbol:String) {
            let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
            let icon = NSImageView(image:NSImage(systemSymbolName:symbol,accessibilityDescription:nil)!); icon.contentTintColor = .secondaryLabelColor; icon.widthAnchor.constraint(equalToConstant:16).isActive = true; icon.heightAnchor.constraint(equalToConstant:16).isActive = true
            let label = NSTextField(labelWithString:name); label.font = .systemFont(ofSize:11); label.textColor = .secondaryLabelColor; label.widthAnchor.constraint(equalToConstant:48).isActive = true
            let control = NSSlider(value:value,minValue:low,maxValue:high,target:self,action:#selector(sliderChanged(_:))); control.tag = tag; settingsSliders[tag] = control; control.controlSize = .small; control.isContinuous = true; control.trackFillColor = ReaderPalette.accent; control.setAccessibilityLabel(name); control.widthAnchor.constraint(equalToConstant:144).isActive = true
            if tag == 2 { control.toolTip = "⌥⌘↑/↓ · App 内亮度，每次 5%" }
            if tag == 3 { control.toolTip = "⌥⌘←/→ · 背景透明度，100% 完全透明" }
            let valueLabel = NSTextField(labelWithString:settingValue(tag,value)); valueLabel.font = .monospacedDigitSystemFont(ofSize:10,weight:.medium); valueLabel.alignment = .right; valueLabel.widthAnchor.constraint(equalToConstant:52).isActive = true; settingsValues[tag] = valueLabel
            for view in [icon,label,control,valueLabel] { row.addArrangedSubview(view) }; add(row)
        }
        if settingsSection == 0 {
            let target = StyledSegment(labels:["正常阅读","摸鱼小窗"],target:self,action:#selector(settingsTabChanged(_:))); target.selectedSegment = settingsTab; target.setAccessibilityLabel("排版目标"); add(target)
            let fonts = NSStackView(); fonts.orientation = .horizontal; fonts.spacing = 8
            for (index,item) in [("serif","宋体"),("system","系统"),("kai","楷体"),("mono","等宽")].enumerated() {
                let b = FontPreviewButton(); b.fontKey = item.0; b.fontLabel = item.1; b.tag = index; b.target = self; b.action = #selector(fontCardChanged(_:)); b.isBordered = false; b.state = (stealth ? p.stealthFontName : p.fontName) == item.0 ? .on : .off; b.toolTip = item.1; b.setAccessibilityLabel("\(item.1)字体预览"); b.widthAnchor.constraint(equalToConstant:65).isActive = true; b.heightAnchor.constraint(equalToConstant:62).isActive = true; fonts.addArrangedSubview(b)
            }
            add(fonts)
            slider(stealth ? 1 : 0,"字号",stealth ? p.stealthFontSize : p.fontSize,stealth ? 8 : 14,stealth ? 20 : 32,"textformat.size")
            slider(stealth ? 5 : 4,"行高",stealth ? p.stealthLineHeight : p.lineHeight,1,stealth ? 2 : 2.2,"line.3.horizontal")
            slider(stealth ? 7 : 6,"段距",stealth ? p.stealthParagraphSpacing : p.paragraphSpacing,0,20,"text.alignleft")
            if !stealth { slider(8,"留白",p.margin,16,90,"arrow.left.and.right") }
        } else if settingsSection == 1 {
            let appearance = StyledSegment(labels:["自动","亮色","暗色"],target:self,action:#selector(themeChanged(_:))); appearance.selectedSegment = ["system","light","dark"].firstIndex(of:p.theme) ?? 0; appearance.setAccessibilityLabel("外观主题"); add(appearance)
            let preview = NSTextField(labelWithString:"山静日长，读一页书。"); preview.font = NSFont(name:"Songti SC",size:21) ?? .systemFont(ofSize:21); preview.alignment = .center; preview.heightAnchor.constraint(equalToConstant:48).isActive = true; add(preview)
            slider(2,"亮度",p.brightness,0,1,"sun.max")
        } else {
            slider(3,"背景透明",1-p.opacity,0,1,"square.dashed")
            slider(9,"文字透明",1-p.textOpacity,0,1,"textformat")
            let auto = MonochromeCheckBox(title:"根据下方画面自动选文字颜色",target:self,action:#selector(toggleAdaptive(_:))); auto.controlSize = .small; auto.font = .systemFont(ofSize:11); auto.state = p.adaptiveText ? .on : .off; add(auto)
            let permissionRow = NSStackView(); permissionRow.orientation = .horizontal; permissionRow.spacing = 8
            let status = NSTextField(labelWithString:""); status.font = .systemFont(ofSize:10); status.textColor = .secondaryLabelColor; status.setContentHuggingPriority(.defaultLow,for:.horizontal); adaptiveStatusLabel = status; permissionRow.addArrangedSubview(status)
            let allow = NSButton(title:"授权…",target:self,action:#selector(requestScreenPermission)); allow.controlSize = .small; allow.bezelStyle = .rounded; permissionButton = allow; permissionRow.addArrangedSubview(allow); add(permissionRow); refreshContrastStatus()
            let actions = NSStackView(); actions.orientation = .horizontal; actions.spacing = 12
            let pin = MonochromeCheckBox(title:"置顶",target:self,action:#selector(toggleFloating(_:))); pin.controlSize = .small; pin.state = p.floating ? .on : .off; actions.addArrangedSubview(pin)
            let clear = NSButton(title:"透明文字",target:self,action:#selector(clearTextPreset)); clear.controlSize = .small; clear.bezelStyle = .rounded; actions.addArrangedSubview(clear); add(actions)
        }
        let hint = NSTextField(labelWithString:settingsSection == 2 ? "双击隐藏 / 恢复 · 悬停左上角显示工具" : "⌘ ± 字号    ⌥⌘ ↑↓ 亮度    ⇧⌘P 翻页 / 滚动"); hint.font = .systemFont(ofSize:9); hint.textColor = .tertiaryLabelColor; fullWidth(hint)

    }
    func interactionOption(_ key:String) -> Bool {
        UserDefaults.standard.object(forKey:key) == nil || UserDefaults.standard.bool(forKey:key)
    }
    @objc func interactionOptionChanged(_ sender:NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        UserDefaults.standard.set(sender.state == .on,forKey:key)
        if key == "ArrowVisibilityEnabled" { if sender.state == .on { visibilityShortcut.start() } else { visibilityShortcut.stop() } }
        if key == "RevealHighlightEnabled", sender.state == .off { active.locator.cancel() }
    }
    @objc func settingsSectionChanged(_ sender:NSSegmentedControl) { guard settingsSection != sender.selectedSegment else { return }; settingsSection = sender.selectedSegment; rebuildSettings() }
    @objc func fontCardChanged(_ sender:NSButton) {
        let names = ["serif","system","kai","mono"]
        guard names.indices.contains(sender.tag) else { return }
        let name = names[sender.tag], character = active.visibleCharacter(), previous = state.preferences
        if settingsTab == 1 { state.preferences.stealthFontName = name } else { state.preferences.fontName = name }
        guard state.preferences != previous else { return }
        if (settingsTab == 1) == isStealth { render(character:character) }
        refreshVisibleSettings(); scheduleSave()
    }
    @objc func showThemeMenu(_ sender:NSButton) {
        let menu = NSMenu()
        for (index,name) in ["跟随系统","亮色","暗色"].enumerated() {
            let item = makeItem(name,#selector(selectTheme(_:))); item.tag = index; item.state = ["system","light","dark"][index] == state.preferences.theme ? .on : .off
            item.image = NSImage(systemSymbolName:["circle.lefthalf.filled","sun.max","moon"][index],accessibilityDescription:nil); menu.addItem(item)
        }
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.maxY+5),in:sender)
    }
    @objc func selectTheme(_ sender:NSMenuItem) { setTheme(["system","light","dark"][sender.tag]) }
    func setTheme(_ theme:String) { guard state.preferences.theme != theme else { return }; state.preferences.theme = theme; let character = active.visibleCharacter(); applyAppearance(); render(character:character); refreshVisibleSettings(structureChanged: true); persist() }
    @objc func clearTextPreset() {
        let character = active.visibleCharacter(), previous = state.preferences
        state.preferences.opacity = 0; state.preferences.textOpacity = 1; state.preferences.adaptiveText = true
        guard state.preferences != previous else { return }
        if isStealth { render(character:character) }; refreshVisibleSettings(); persist()
    }
    @objc func themeChanged(_ sender: NSSegmentedControl) { setTheme(["system","light","dark"][sender.selectedSegment]) }
    @objc func settingsTabChanged(_ sender: NSSegmentedControl) { guard settingsTab != sender.selectedSegment else { return }; settingsTab = sender.selectedSegment; rebuildSettings() }
    func settingValue(_ tag:Int,_ value:Double) -> String {
        if tag == 4 || tag == 5 { return String(format:"%.2f×",value) }
        if tag == 2 || tag == 3 || tag == 9 { return "\(Int((value*100).rounded()))%" }
        return "\(Int(value.rounded())) pt"
    }
    @objc func sliderChanged(_ sender: NSSlider) {
        let anchor = active.visibleCharacter(), value = sender.doubleValue, previous = state.preferences
        switch sender.tag {
        case 0: state.preferences.fontSize = value
        case 1: state.preferences.stealthFontSize = value
        case 2: state.preferences.brightness = value
        case 3: state.preferences.opacity = 1-value
        case 4: state.preferences.lineHeight = value
        case 5: state.preferences.stealthLineHeight = value
        case 6: state.preferences.paragraphSpacing = value
        case 7: state.preferences.stealthParagraphSpacing = value
        case 9: state.preferences.textOpacity = 1-value
        case 8: state.preferences.margin = value
        default: return
        }
        guard state.preferences != previous else { return }
        settingsValues[sender.tag]?.stringValue = settingValue(sender.tag,value)
        let affectsActive = sender.tag == 2 || (isStealth ? [1,3,5,7,9].contains(sender.tag) : [0,4,6,8].contains(sender.tag))
        if affectsActive { render(character:anchor); recordPosition() }
        scheduleSave()
    }
    @objc func toggleFloating(_ sender: NSButton) { guard state.preferences.floating != (sender.state == .on) else { return }; state.preferences.floating = sender.state == .on; mini.level = state.preferences.floating ? .floating : .normal; syncHoverToolbar(); persist() }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"moread",.applicationVersion:"1.3",.credits:NSAttributedString(string:"原生本地阅读器\nEPUB · 无框小窗 · 离线阅读")]) }
    func showError(_ error: Error) { if let errorHandler { errorHandler(error); return }; let alert = NSAlert(); alert.messageText = "无法完成操作"; alert.informativeText = error.localizedDescription; alert.addButton(withTitle:"好"); alert.runModal() }
}
