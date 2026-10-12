import AppKit
import UniformTypeIdentifiers
import ReaderCore

final class ReaderApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var window: NSWindow!
    var mini: StealthWindow!
    let normalSurface = ReaderSurface(frame: .zero), miniSurface = ReaderSurface(frame: .zero)
    let table = NSTableView(), search = NSSearchField(), bookPicker = NSPopUpButton()
    let titleLabel = NSTextField(labelWithString: "闲读"), subtitleLabel = NSTextField(labelWithString: "本地阅读 · 自在留白")
    let progressLabel = NSTextField(labelWithString: ""), chapterLabel = NSTextField(labelWithString: "")
    var state = LibraryState(), currentChapter = 0, currentText = "", filtered: [Int] = []
    var isStealth = false, importing = false, rendering = false
    var settings: NSPanel?, statusItem: NSStatusItem!, saveWork: DispatchWorkItem?
    let support: URL
    var stateURL: URL { support.appendingPathComponent("library.json") }
    var book: Book? { state.books.first { $0.id == state.selectedBook } }
    var active: ReaderSurface { isStealth ? miniSurface : normalSurface }
    var settingsValues: [Int:NSTextField] = [:]
    var contentPanel: NSView!
    var settingsTab = 0
    var appearanceObserver: NSObjectProtocol?
    var dark: Bool { state.preferences.theme == "dark" || (state.preferences.theme == "system" && NSApp.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua) }
    override init() {
        support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MudsReader")
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: stateURL.path) { state = try LibraryState.load(from: stateURL) }
        } catch { showError(error) }
        applyAppearance(); buildMenus(); buildWindow(); buildMini(); refreshLibrary()
        isStealth = UserDefaults.standard.bool(forKey:"StealthMode")
        appearanceObserver = DistributedNotificationCenter.default().addObserver(forName:NSNotification.Name("AppleInterfaceThemeChangedNotification"),object:nil,queue:.main) { [weak self] _ in
            guard let self, self.state.preferences.theme == "system" else { return }
            self.applyAppearance(); self.render(character:self.active.visibleCharacter())
        }
        if let book {
            let position = state.positions[book.id] ?? ReadingPosition()
            openChapter(min(position.chapter,book.chapters.count-1), character: position.character)
        }
        showReader()
        if let i = CommandLine.arguments.firstIndex(of: "--import"), CommandLine.arguments.count > i+1 { importURL(URL(fileURLWithPath: CommandLine.arguments[i+1])) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showReader(); return true }
    func applicationWillTerminate(_ notification: Notification) { recordPosition(); persist() }
    func windowWillClose(_ notification: Notification) { recordPosition(); persist() }
    func windowDidResignKey(_ notification: Notification) { recordPosition(); persist() }
    func application(_ sender: NSApplication, openFiles filenames: [String]) { if let file = filenames.first { importURL(URL(fileURLWithPath:file)) }; sender.reply(toOpenOrPrint: .success) }
    func makeItem(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; item.keyEquivalentModifierMask = modifiers; return item
    }
    func buildMenus() {
        let main = NSMenu()
        let appMenu = NSMenu(); appMenu.addItem(makeItem("关于闲读",#selector(about))); appMenu.addItem(.separator())
        appMenu.addItem(makeItem("阅读设置…",#selector(showSettings),key:",")); appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title:"隐藏闲读",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")); appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title:"退出闲读",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"))
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)
        let fileMenu = NSMenu(title:"文件"); fileMenu.addItem(makeItem("导入 EPUB…",#selector(importBook),key:"o")); fileMenu.addItem(makeItem("从 Apple Books 导入…",#selector(importFromBooks))); fileMenu.addItem(.separator()); fileMenu.addItem(makeItem("显示阅读器",#selector(showReader))); fileMenu.addItem(makeItem("关闭窗口",#selector(closeWindow),key:"w"))
        let file = NSMenuItem(); file.submenu = fileMenu; main.addItem(file)
        let reading = NSMenu(title:"阅读"); reading.addItem(makeItem("切换摸鱼模式",#selector(toggleStealth),key:"m",modifiers:[.command,.shift])); reading.addItem(makeItem("上一页",#selector(previousPage),key:String(UnicodeScalar(NSLeftArrowFunctionKey)!),modifiers:[])); reading.addItem(makeItem("下一页",#selector(nextPage),key:String(UnicodeScalar(NSRightArrowFunctionKey)!),modifiers:[])); reading.addItem(.separator()); reading.addItem(makeItem("上一章",#selector(previousChapter),key:"[")); reading.addItem(makeItem("下一章",#selector(nextChapter),key:"]")); reading.addItem(makeItem("搜索目录",#selector(focusSearch),key:"f")); reading.addItem(.separator()); reading.addItem(makeItem("放大文字",#selector(larger),key:"=")); reading.addItem(makeItem("缩小文字",#selector(smaller),key:"-"))
        let read = NSMenuItem(); read.submenu = reading; main.addItem(read); NSApp.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName:"book.closed",accessibilityDescription:"闲读")
        statusItem.menu = contextMenu()
    }
    func contextMenu() -> NSMenu {
        let menu = NSMenu(); menu.addItem(makeItem("显示阅读器",#selector(showReader))); menu.addItem(makeItem("切换摸鱼模式 ⇧⌘M",#selector(toggleStealth))); menu.addItem(makeItem("阅读设置… ⌘,",#selector(showSettings))); menu.addItem(.separator()); menu.addItem(makeItem("上一章",#selector(previousChapter))); menu.addItem(makeItem("下一章",#selector(nextChapter))); menu.addItem(.separator()); menu.addItem(makeItem("隐藏窗口 Esc",#selector(hideReader))); return menu
    }
    func button(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let b = NSButton(image:NSImage(systemSymbolName:symbol,accessibilityDescription:label)!,target:self,action:action)
        b.contentTintColor = .secondaryLabelColor; b.bezelStyle = .texturedRounded; b.isBordered = false; b.toolTip = label; b.setAccessibilityLabel(label)
        b.translatesAutoresizingMaskIntoConstraints = false; b.widthAnchor.constraint(equalToConstant:32).isActive = true; b.heightAnchor.constraint(equalToConstant:30).isActive = true
        return b
    }
    func buildWindow() {
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1020,height:740),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title = "闲读"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.minSize = NSSize(width:720,height:460); window.isReleasedWhenClosed = false; window.delegate = self
        window.setFrameAutosaveName("MainReaderWindow"); if !window.setFrameUsingName("MainReaderWindow") { window.center() }
        let root = NSView(); root.wantsLayer = true; root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor; window.contentView = root
        let sidebar = NSVisualEffectView(); sidebar.material = .sidebar; sidebar.blendingMode = .behindWindow; sidebar.state = .active
        let content = NSView(); contentPanel = content; content.wantsLayer = true; content.layer?.backgroundColor = pageColor.cgColor
        for view in [sidebar,content] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([sidebar.leadingAnchor.constraint(equalTo:root.leadingAnchor),sidebar.topAnchor.constraint(equalTo:root.topAnchor),sidebar.bottomAnchor.constraint(equalTo:root.bottomAnchor),sidebar.widthAnchor.constraint(equalToConstant:238),content.leadingAnchor.constraint(equalTo:sidebar.trailingAnchor),content.trailingAnchor.constraint(equalTo:root.trailingAnchor),content.topAnchor.constraint(equalTo:root.topAnchor),content.bottomAnchor.constraint(equalTo:root.bottomAnchor)])
        let brand = NSTextField(labelWithString:"闲读"); brand.font = .systemFont(ofSize:24,weight:.semibold)
        let local = NSTextField(labelWithString:"我的书架"); local.font = .systemFont(ofSize:11,weight:.medium); local.textColor = .secondaryLabelColor
        bookPicker.target = self; bookPicker.action = #selector(selectBook); bookPicker.setAccessibilityLabel("我的书架")
        search.placeholderString = "搜索章节"; search.delegate = self; search.setAccessibilityLabel("搜索章节")
        let importButton = NSButton(title:"导入书籍",image:NSImage(systemSymbolName:"plus",accessibilityDescription:nil)!,target:self,action:#selector(importBook)); importButton.bezelStyle = .rounded
        let tableScroll = NSScrollView(); tableScroll.documentView = table; tableScroll.hasVerticalScroller = true; tableScroll.autohidesScrollers = true; tableScroll.drawsBackground = false
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("chapter")); column.width = 207; table.addTableColumn(column); table.headerView = nil; table.backgroundColor = .clear; table.rowHeight = 35; table.style = .sourceList; table.delegate = self; table.dataSource = self; table.target = self; table.action = #selector(selectChapter); table.setAccessibilityLabel("章节目录")
        for v in [brand,local,bookPicker,search,tableScroll,importButton] { v.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(v) }
        NSLayoutConstraint.activate([brand.topAnchor.constraint(equalTo:sidebar.topAnchor,constant:52),brand.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:22),local.topAnchor.constraint(equalTo:brand.bottomAnchor,constant:23),local.leadingAnchor.constraint(equalTo:brand.leadingAnchor),bookPicker.topAnchor.constraint(equalTo:local.bottomAnchor,constant:8),bookPicker.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:16),bookPicker.trailingAnchor.constraint(equalTo:sidebar.trailingAnchor,constant:-16),search.topAnchor.constraint(equalTo:bookPicker.bottomAnchor,constant:18),search.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:18),search.trailingAnchor.constraint(equalTo:sidebar.trailingAnchor,constant:-18),tableScroll.topAnchor.constraint(equalTo:search.bottomAnchor,constant:14),tableScroll.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:8),tableScroll.trailingAnchor.constraint(equalTo:sidebar.trailingAnchor,constant:-8),tableScroll.bottomAnchor.constraint(equalTo:importButton.topAnchor,constant:-14),importButton.bottomAnchor.constraint(equalTo:sidebar.bottomAnchor,constant:-18),importButton.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:18),importButton.trailingAnchor.constraint(equalTo:sidebar.trailingAnchor,constant:-18)])
        titleLabel.font = .systemFont(ofSize:22,weight:.semibold); titleLabel.textColor = .labelColor
        subtitleLabel.font = .systemFont(ofSize:11); subtitleLabel.textColor = .secondaryLabelColor
        chapterLabel.font = .systemFont(ofSize:12,weight:.medium); chapterLabel.textColor = .secondaryLabelColor; chapterLabel.lineBreakMode = .byTruncatingTail
        progressLabel.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular); progressLabel.textColor = .secondaryLabelColor
        let mode = button("rectangle.compress.vertical","摸鱼模式 ⇧⌘M",#selector(toggleStealth)), settings = button("textformat.size","阅读设置 ⌘,",#selector(showSettings)), prev = button("chevron.left","上一章 ⌘[",#selector(previousChapter)), next = button("chevron.right","下一章 ⌘]",#selector(nextChapter))
        let line = NSBox(); line.boxType = .separator
        for v in [titleLabel,subtitleLabel,chapterLabel,progressLabel,mode,settings,prev,next,line,normalSurface] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([titleLabel.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:52),titleLabel.topAnchor.constraint(equalTo:content.topAnchor,constant:45),titleLabel.trailingAnchor.constraint(lessThanOrEqualTo:settings.leadingAnchor,constant:-16),subtitleLabel.leadingAnchor.constraint(equalTo:titleLabel.leadingAnchor),subtitleLabel.topAnchor.constraint(equalTo:titleLabel.bottomAnchor,constant:7),mode.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-32),mode.centerYAnchor.constraint(equalTo:titleLabel.centerYAnchor),settings.trailingAnchor.constraint(equalTo:mode.leadingAnchor,constant:-9),settings.centerYAnchor.constraint(equalTo:mode.centerYAnchor),line.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:52),line.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-52),line.topAnchor.constraint(equalTo:subtitleLabel.bottomAnchor,constant:24),normalSurface.topAnchor.constraint(equalTo:line.bottomAnchor,constant:3),normalSurface.leadingAnchor.constraint(equalTo:content.leadingAnchor),normalSurface.trailingAnchor.constraint(equalTo:content.trailingAnchor),normalSurface.bottomAnchor.constraint(equalTo:chapterLabel.topAnchor,constant:-16),chapterLabel.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:52),chapterLabel.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-23),chapterLabel.trailingAnchor.constraint(lessThanOrEqualTo:progressLabel.leadingAnchor,constant:-16),next.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-27),next.centerYAnchor.constraint(equalTo:chapterLabel.centerYAnchor),prev.trailingAnchor.constraint(equalTo:next.leadingAnchor,constant:-2),prev.centerYAnchor.constraint(equalTo:next.centerYAnchor),progressLabel.trailingAnchor.constraint(equalTo:prev.leadingAnchor,constant:-16),progressLabel.centerYAnchor.constraint(equalTo:chapterLabel.centerYAnchor)])
        configure(normalSurface)
    }
    func buildMini() {
        mini = StealthWindow(contentRect:NSRect(x:0,y:0,width:360,height:150),styleMask:[.borderless,.resizable],backing:.buffered,defer:false)
        mini.title = "闲读 · 摸鱼"; mini.minSize = NSSize(width:160,height:64); mini.isReleasedWhenClosed = false; mini.delegate = self
        mini.hasShadow = false; mini.isOpaque = false; mini.backgroundColor = .clear
        mini.level = state.preferences.floating ? .floating : .normal
        mini.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        mini.contentView = miniSurface; mini.setFrameAutosaveName("StealthReaderWindow"); if !mini.setFrameUsingName("StealthReaderWindow") { mini.center() }; configure(miniSurface)
    }
    func configure(_ surface: ReaderSurface) {
        surface.text.turnPage = { [weak self] in self?.turnPage($0) }
        surface.text.hideReader = { [weak self] in self?.hideReader() }
        surface.text.menu = contextMenu()
        surface.didScroll = { [weak self] in guard let self, !self.rendering else { return }; self.recordPosition(); self.updateProgress(); self.scheduleSave() }
    }
    func refreshLibrary() {
        bookPicker.removeAllItems()
        if state.books.isEmpty { bookPicker.addItem(withTitle:"尚未导入书籍"); bookPicker.isEnabled = false }
        else { bookPicker.isEnabled = true; bookPicker.addItems(withTitles:state.books.map(\.title)); if let index = state.books.firstIndex(where:{$0.id == state.selectedBook}) { bookPicker.selectItem(at:index) } }
        titleLabel.stringValue = book?.title ?? "留一点时间，给阅读"
        subtitleLabel.stringValue = book.map { "\($0.author)  ·  \($0.chapters.count) 节" } ?? "导入一本 EPUB，开始阅读"
        filterChapters()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let book, filtered.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("ChapterCell")
        let cell = (tableView.makeView(withIdentifier:id,owner:self) as? NSTableCellView) ?? NSTableCellView()
        if cell.textField == nil {
            cell.identifier = id; let field = NSTextField(labelWithString:""); field.font = .systemFont(ofSize:12); field.lineBreakMode = .byTruncatingTail; field.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(field); cell.textField = field
            NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:8),field.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-6),field.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
        }
        cell.textField?.stringValue = book.chapters[filtered[row]].title; cell.toolTip = cell.textField?.stringValue
        return cell
    }
    func controlTextDidChange(_ obj: Notification) { filterChapters() }
    func filterChapters() {
        let query = search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        filtered = book?.chapters.indices.filter { query.isEmpty || book!.chapters[$0].title.localizedCaseInsensitiveContains(query) } ?? []
        table.reloadData(); selectCurrentRow()
    }
    func selectCurrentRow() { if let row = filtered.firstIndex(of:currentChapter) { table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); table.scrollRowToVisible(row) } }
    @objc func selectChapter() { guard filtered.indices.contains(table.selectedRow) else { return }; recordPosition(); openChapter(filtered[table.selectedRow]) }
    @objc func selectBook() {
        guard state.books.indices.contains(bookPicker.indexOfSelectedItem) else { return }
        recordPosition(); state.selectedBook = state.books[bookPicker.indexOfSelectedItem].id; refreshLibrary()
        let pos = state.positions[state.selectedBook!] ?? ReadingPosition(); openChapter(pos.chapter,character:pos.character)
    }
    func openChapter(_ chapter: Int, character: Int = 0, end: Bool = false) {
        guard let book, book.chapters.indices.contains(chapter) else { return }
        do {
            let text = try book.text(at:chapter)
            rendering = true; currentChapter = chapter; currentText = text.isEmpty ? "本节没有文字内容" : text
            render(character:character); if end { active.goToEnd() }
            rendering = false; selectCurrentRow(); recordPosition(); updateProgress(); persist()
            (isStealth ? mini : window)?.makeFirstResponder(active.text)
        } catch { rendering = false; showError(error) }
    }
    func render(character: Int) {
        let p = state.preferences
        active.display(currentText,fontSize:isStealth ? p.stealthFontSize : p.fontSize,brightness:p.brightness,stealth:isStealth,character:character,dark:dark,fontName:isStealth ? p.stealthFontName : p.fontName,lineHeight:isStealth ? p.stealthLineHeight : p.lineHeight,paragraphSpacing:isStealth ? p.stealthParagraphSpacing : p.paragraphSpacing,margin:p.margin)
        contentPanel?.layer?.backgroundColor = pageColor.cgColor
        mini.alphaValue = p.opacity; mini.level = p.floating ? .floating : .normal
    }
    func recordPosition() {
        guard !rendering, let book else { return }
        state.positions[book.id] = ReadingPosition(chapter:currentChapter,character:active.visibleCharacter())
    }
    func updateProgress() {
        guard let book else { return }
        chapterLabel.stringValue = book.chapters[currentChapter].title
        let fraction = Double(active.visibleCharacter()) / Double(max(1,(currentText as NSString).length))
        let percent = 100 * (Double(currentChapter)+fraction) / Double(book.chapters.count)
        progressLabel.stringValue = String(format:"%d / %d  ·  %.1f%%",currentChapter+1,book.chapters.count,percent)
    }
    func scheduleSave() { saveWork?.cancel(); let work = DispatchWorkItem { [weak self] in self?.persist() }; saveWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.35,execute:work) }
    func persist() { saveWork?.cancel(); do { try state.save(to:stateURL) } catch { showError(error) } }
    func turnPage(_ direction: Int) {
        guard let book else { return }
        if active.page(direction) {
            let next = currentChapter+direction
            if book.chapters.indices.contains(next) { openChapter(next,end:direction < 0) }
        }
    }
    @objc func nextPage() { turnPage(1) }
    @objc func previousPage() { turnPage(-1) }
    @objc func nextChapter() { recordPosition(); openChapter(currentChapter+1) }
    @objc func previousChapter() { recordPosition(); openChapter(currentChapter-1) }
    @objc func focusSearch() { if isStealth { toggleStealth() }; window.makeFirstResponder(search) }
    @objc func toggleStealth() {
        guard book != nil else { importBook(); return }
        recordPosition(); let character = state.positions[book!.id]?.character ?? 0
        isStealth.toggle(); UserDefaults.standard.set(isStealth,forKey:"StealthMode"); rendering = true; render(character:character); rendering = false
        if isStealth { window.orderOut(nil); mini.makeKeyAndOrderFront(nil); mini.makeFirstResponder(miniSurface.text) }
        else { mini.orderOut(nil); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(normalSurface.text) }
        updateProgress(); persist(); NSApp.activate(ignoringOtherApps:true)
    }
    @objc func hideReader() { recordPosition(); persist(); (isStealth ? mini : window)?.orderOut(nil); settings?.orderOut(nil) }
    @objc func closeWindow() { hideReader() }
    @objc func showReader() { (isStealth ? mini : window)?.makeKeyAndOrderFront(nil); (isStealth ? mini : window)?.makeFirstResponder(active.text); NSApp.activate(ignoringOtherApps:true) }
    @objc func larger() { changeFont(1) }
    @objc func smaller() { changeFont(-1) }
    func changeFont(_ delta: Double) {
        let anchor = active.visibleCharacter()
        if isStealth { state.preferences.stealthFontSize = min(20,max(8,state.preferences.stealthFontSize+delta)) } else { state.preferences.fontSize = min(32,max(14,state.preferences.fontSize+delta)) }
        render(character:anchor); persist()
    }
    @objc func importBook() { openImportPanel(directory:nil) }
    @objc func importFromBooks() { openImportPanel(directory:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/iCloud~com~apple~iBooks/Documents")) }
    func openImportPanel(directory: URL?) {
        let panel = NSOpenPanel(); panel.title = "导入 EPUB"; panel.allowedContentTypes = [UTType(filenameExtension:"epub") ?? .data]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = true; panel.treatsFilePackagesAsDirectories = false; panel.directoryURL = directory
        panel.begin { [weak self] response in if response == .OK, let url = panel.url { self?.importURL(url) } }
    }
    func importURL(_ url: URL) {
        guard !importing else { return }; importing = true; subtitleLabel.stringValue = "正在导入…"
        let library = support.appendingPathComponent("Books")
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try EPUB.importBook(from:url,library:library) }
            DispatchQueue.main.async {
                guard let self else { return }; self.importing = false
                switch result {
                case .success(let newBook): self.recordPosition(); self.state.books.append(newBook); self.state.selectedBook = newBook.id; self.currentChapter = 0; self.search.stringValue = ""; self.refreshLibrary(); self.openChapter(0); self.showReader()
                case .failure(let error): self.refreshLibrary(); self.showError(error)
                }
            }
        }
    }
    var pageColor: NSColor { dark ? NSColor.black : NSColor(calibratedRed:0.973,green:0.961,blue:0.930,alpha:1) }
    func applyAppearance() {
        switch state.preferences.theme { case "dark": NSApp.appearance = NSAppearance(named:.darkAqua); case "light": NSApp.appearance = NSAppearance(named:.aqua); default: NSApp.appearance = nil }
    }
    @objc func showSettings() {
        if settings == nil {
            let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:390,height:580),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            panel.title = "排版与外观"; panel.isReleasedWhenClosed = false; panel.level = .floating
            settings = panel; settingsTab = isStealth ? 1 : 0; rebuildSettings(); panel.center()
        }
        settings?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func rebuildSettings() {
        guard let panel = settings else { return }; settingsValues.removeAll()
        let root = NSView(); panel.contentView = root
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 17; stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo:root.topAnchor,constant:24),stack.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:28),stack.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-28)])
        let heading = NSTextField(labelWithString:"把阅读调成你的样子"); heading.font = .systemFont(ofSize:20,weight:.semibold); stack.addArrangedSubview(heading)
        let theme = NSSegmentedControl(labels:["跟随系统","纸白","夜读"],trackingMode:.selectOne,target:self,action:#selector(themeChanged(_:))); theme.selectedSegment = ["system","light","dark"].firstIndex(of:state.preferences.theme) ?? 0; theme.setAccessibilityLabel("外观主题"); theme.widthAnchor.constraint(equalToConstant:334).isActive = true; stack.addArrangedSubview(theme)
        let divider = NSBox(); divider.boxType = .separator; divider.widthAnchor.constraint(equalToConstant:334).isActive = true; stack.addArrangedSubview(divider)
        let tabs = NSSegmentedControl(labels:["正常阅读","摸鱼小窗"],trackingMode:.selectOne,target:self,action:#selector(settingsTabChanged(_:))); tabs.selectedSegment = settingsTab; tabs.widthAnchor.constraint(equalToConstant:334).isActive = true; tabs.setAccessibilityLabel("设置模式"); stack.addArrangedSubview(tabs)
        let p = state.preferences, stealth = settingsTab == 1
        let font = NSPopUpButton(); font.addItems(withTitles:["宋体 · 书卷","系统 · 简净","等宽 · 专注"]); font.selectItem(at:["serif","system","mono"].firstIndex(of:stealth ? p.stealthFontName : p.fontName) ?? 0); font.target = self; font.action = #selector(fontChanged(_:)); font.setAccessibilityLabel("阅读字体"); font.widthAnchor.constraint(equalToConstant:334).isActive = true; stack.addArrangedSubview(font)
        let rows: [(Int,String,Double,Double,Double)] = stealth ? [(1,"字号",p.stealthFontSize,8,20),(5,"行高",p.stealthLineHeight,1,2),(7,"段落间距",p.stealthParagraphSpacing,0,16),(2,"窗口明暗",p.brightness,0,1),(3,"窗口透明度",1-p.opacity,0,0.8)] : [(0,"字号",p.fontSize,14,32),(4,"行高",p.lineHeight,1,2.2),(6,"段落间距",p.paragraphSpacing,0,20),(8,"页边距",p.margin,16,90)]
        for (tag,name,value,low,high) in rows {
            let row = NSStackView(); row.orientation = .vertical; row.alignment = .leading; row.spacing = 5
            let label = NSTextField(labelWithString:settingLabel(tag,name,value)); label.font = .systemFont(ofSize:12,weight:.medium); settingsValues[tag] = label
            let slider = NSSlider(value:value,minValue:low,maxValue:high,target:self,action:#selector(sliderChanged(_:))); slider.tag = tag; slider.isContinuous = true; slider.setAccessibilityLabel(name); slider.widthAnchor.constraint(equalToConstant:334).isActive = true
            row.addArrangedSubview(label); row.addArrangedSubview(slider); stack.addArrangedSubview(row)
        }
        if stealth {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 14
            let check = NSButton(checkboxWithTitle:"始终置顶",target:self,action:#selector(toggleFloating(_:))); check.state = p.floating ? .on : .off; row.addArrangedSubview(check)
            let black = NSButton(title:"黑底白字",target:self,action:#selector(blackStealth)); black.bezelStyle = .rounded; row.addArrangedSubview(black); stack.addArrangedSubview(row)
        }
        let hint = NSTextField(labelWithString:"⇧⌘M 切换模式    ⌘, 设置    Esc 隐藏"); hint.font = .systemFont(ofSize:10); hint.textColor = .secondaryLabelColor; stack.addArrangedSubview(hint)
    }
    @objc func themeChanged(_ sender: NSSegmentedControl) { state.preferences.theme = ["system","light","dark"][sender.selectedSegment]; let anchor = active.visibleCharacter(); applyAppearance(); render(character:anchor); persist() }
    @objc func settingsTabChanged(_ sender: NSSegmentedControl) { settingsTab = sender.selectedSegment; rebuildSettings() }
    @objc func fontChanged(_ sender: NSPopUpButton) { let name = ["serif","system","mono"][sender.indexOfSelectedItem]; let anchor = active.visibleCharacter(); if settingsTab == 1 { state.preferences.stealthFontName = name } else { state.preferences.fontName = name }; render(character:anchor); persist() }
    @objc func blackStealth() { let anchor = active.visibleCharacter(); state.preferences.brightness = 0; state.preferences.opacity = 1; render(character:anchor); rebuildSettings(); persist() }
    func settingLabel(_ tag: Int, _ name: String, _ value: Double) -> String {
        if tag == 4 || tag == 5 { return String(format:"%@  %.2f×",name,value) }
        if tag == 2 || tag == 3 { return "\(name)  \(Int((value*100).rounded()))%" }
        return "\(name)  \(Int(value.rounded())) pt"
    }
    @objc func sliderChanged(_ sender: NSSlider) {
        let anchor = active.visibleCharacter(), value = sender.doubleValue
        switch sender.tag {
        case 0: state.preferences.fontSize = value
        case 1: state.preferences.stealthFontSize = value
        case 2: state.preferences.brightness = value
        case 3: state.preferences.opacity = 1-value
        case 4: state.preferences.lineHeight = value
        case 5: state.preferences.stealthLineHeight = value
        case 6: state.preferences.paragraphSpacing = value
        case 7: state.preferences.stealthParagraphSpacing = value
        default: state.preferences.margin = value
        }
        let names = ["字号","字号","窗口明暗","窗口透明度","行高","行高","段落间距","段落间距","页边距"]
        settingsValues[sender.tag]?.stringValue = settingLabel(sender.tag,names[sender.tag],value)
        render(character:anchor); recordPosition(); scheduleSave()
    }
    @objc func toggleFloating(_ sender: NSButton) { state.preferences.floating = sender.state == .on; mini.level = state.preferences.floating ? .floating : .normal; persist() }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"闲读 · MudsReader",.applicationVersion:"1.0",.credits:NSAttributedString(string:"原生本地阅读器\nEPUB · 无框小窗 · 离线阅读")]) }
    func showError(_ error: Error) { let alert = NSAlert(); alert.messageText = "无法完成操作"; alert.informativeText = error.localizedDescription; alert.addButton(withTitle:"好"); alert.runModal() }
}
