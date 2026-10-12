import AppKit
import ReaderCore

private final class ChapterTable: NSTableView {
    var activateSelection: (() -> Void)?
    override func keyDown(with event:NSEvent) { if event.keyCode == 36 || event.keyCode == 76 { activateSelection?() } else { super.keyDown(with:event) } }
}
@MainActor final class ChapterPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:290,height:360),styleMask:[.titled,.closable,.utilityWindow],backing:.buffered,defer:false)
    let search = NSSearchField()
    private let table = ChapterTable()
    private var chapters: [Chapter] = []
    private var filtered: [Int] = []
    private var current = 0
    var onSelect: ((Int) -> Void)?
    override init() {
        super.init(); panel.title = "目录"; panel.level = .floating; panel.isReleasedWhenClosed = false; panel.delegate = self; panel.titlebarAppearsTransparent = true
        let root = NSView(); root.wantsLayer = true; panel.contentView = root
        search.placeholderString = "搜索章节"; search.delegate = self; search.controlSize = .small; search.focusRingType = .none; search.setAccessibilityLabel("目录搜索")
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = table
        let col = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("chapter")); col.width = 258; table.addTableColumn(col)
        table.headerView = nil; table.rowHeight = 29; table.backgroundColor = .clear; table.style = .plain; table.delegate = self; table.dataSource = self; table.target = self; table.action = #selector(choose); table.activateSelection = { [weak self] in self?.choose() }; table.setAccessibilityLabel("章节目录")
        for view in [search,scroll] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([search.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:12),search.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-12),search.topAnchor.constraint(equalTo:root.topAnchor,constant:12),scroll.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:8),scroll.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-8),scroll.topAnchor.constraint(equalTo:search.bottomAnchor,constant:10),scroll.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-8)])
    }
    func present(book:Book,chapter:Int,near anchor:NSRect,screen:NSRect) {
        chapters = book.chapters; current = chapter; search.stringValue = ""; panel.title = "目录 · \(book.title)"
        panel.contentView?.layer?.backgroundColor = ReaderPalette.panel.cgColor
        reload()
        let x = max(screen.minX,min(anchor.minX,screen.maxX-panel.frame.width))
        let y = max(screen.minY,min(anchor.minY-panel.frame.height-6,screen.maxY-panel.frame.height))
        panel.setFrameOrigin(NSPoint(x:x,y:y)); panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(search); NSApp.activate(ignoringOtherApps:true)
    }
    func close() { panel.orderOut(nil) }
    func windowDidResignKey(_ notification:Notification) { close() }
    func controlTextDidChange(_ obj:Notification) { reload() }
    func control(_ control:NSControl,textView:NSTextView,doCommandBy commandSelector:Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) { panel.makeFirstResponder(table); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { choose(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        return false
    }
    private func reload() {
        let query = search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        filtered = chapters.indices.filter { query.isEmpty || chapters[$0].title.localizedCaseInsensitiveContains(query) }; table.reloadData()
        if !filtered.isEmpty { let row = filtered.firstIndex(of:current) ?? 0; table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); table.scrollRowToVisible(row) }
    }
    func numberOfRows(in tableView:NSTableView) -> Int { filtered.count }
    func tableView(_ tableView:NSTableView,rowViewForRow row:Int) -> NSTableRowView? { ReaderRowView() }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("chapter-cell"), cell = (tableView.makeView(withIdentifier:NSUserInterfaceItemIdentifier("chapter-cell"),owner:self) as? NSTableCellView) ?? NSTableCellView()
        if cell.textField == nil {
            cell.identifier = id; let field = NSTextField(labelWithString:""); field.font = .systemFont(ofSize:12); field.lineBreakMode = .byTruncatingTail; field.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(field); cell.textField = field
            NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:7),field.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-7),field.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
        }
        cell.textField?.stringValue = chapters[filtered[row]].title; cell.textField?.textColor = .labelColor; cell.toolTip = chapters[filtered[row]].title; return cell
    }
    @objc private func choose() { guard filtered.indices.contains(table.selectedRow) else { return }; let index = filtered[table.selectedRow]; close(); onSelect?(index) }
}
