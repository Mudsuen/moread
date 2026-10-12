import AppKit

final class ReadingTextView: NSTextView {
    var turnPage: ((Int) -> Void)?
    var hideReader: (() -> Void)?
    var stealth = false
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123,126,116: turnPage?(-1)
        case 124,125,121: turnPage?(1)
        case 49: turnPage?(event.modifierFlags.contains(.shift) ? -1 : 1)
        case 53: hideReader?()
        default: super.keyDown(with: event)
        }
    }
    override func rightMouseDown(with event: NSEvent) {
        if let menu { NSMenu.popUpContextMenu(menu,with:event,for:self) }
        else { super.rightMouseDown(with:event) }
    }
    override func mouseDown(with event: NSEvent) {
        if stealth { window?.performDrag(with: event) } else { super.mouseDown(with: event) }
    }
}
final class StealthWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
final class ReaderSurface: NSView {
    let scroll = NSScrollView()
    let text = ReadingTextView()
    var didScroll: (() -> Void)?
    private var observer: NSObjectProtocol?
    private var lastWidth: CGFloat = 0
    private var changing = false
    var anchor = 0
    var stealth = false
    private var readingMargin: Double = 48
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        text.isEditable = false; text.isSelectable = true
        text.isRichText = false; text.drawsBackground = false
        text.isHorizontallyResizable = false; text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.lineFragmentPadding = 0
        scroll.documentView = text
        addSubview(scroll)
        scroll.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            guard let self, !self.changing else { return }
            self.anchor = self.visibleCharacter(); self.didScroll?()
        }
        setAccessibilityLabel("阅读正文")
        text.setAccessibilityLabel("阅读正文")
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    override func layout() {
        let oldAnchor = anchor
        changing = true
        super.layout(); scroll.frame = bounds
        let width = max(20, bounds.width)
        text.textContainerInset.width = stealth ? 10 : min(readingMargin,max(16,width*0.16))
        text.frame.size.width = width
        text.textContainer?.containerSize = NSSize(width: max(10,width - text.textContainerInset.width*2), height: .greatestFiniteMagnitude)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let used = text.layoutManager?.usedRect(for: text.textContainer!).height ?? 0
        text.frame.size.height = max(scroll.contentSize.height, used + text.textContainerInset.height*2 + 8)
        changing = false
        if lastWidth != width { lastWidth = width; restore(oldAnchor) }
    }
    func display(_ string: String, fontSize: CGFloat, brightness: Double, stealth: Bool, character: Int, dark: Bool, fontName: String, lineHeight: Double, paragraphSpacing: Double, margin: Double) {
        changing = true; self.stealth = stealth; text.stealth = stealth; readingMargin = margin
        scroll.hasVerticalScroller = !stealth
        text.isSelectable = !stealth
        text.textContainerInset = stealth ? NSSize(width: 10,height: 7) : NSSize(width: min(margin,max(16,bounds.width*0.16)),height: 24)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = lineHeight
        paragraph.paragraphSpacing = paragraphSpacing
        paragraph.lineBreakMode = .byWordWrapping
        let font: NSFont
        switch fontName { case "serif": font = NSFont(name:"Songti SC",size:fontSize) ?? .systemFont(ofSize:fontSize); case "mono": font = .monospacedSystemFont(ofSize:fontSize,weight:.regular); default: font = .systemFont(ofSize:fontSize) }
        let background = stealth ? NSColor(white: brightness, alpha: 1) : (dark ? NSColor.black : NSColor(calibratedRed: 0.973, green: 0.961, blue: 0.930, alpha: 1))
        let foreground = stealth ? NSColor(white: brightness < 0.45 ? 0.96 : 0.14, alpha: 1) : (dark ? NSColor(calibratedWhite:0.92,alpha:1) : NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.20, alpha: 1))
        layer?.backgroundColor = background.cgColor
        let attributed = NSMutableAttributedString(string: string, attributes: [.font:font,.foregroundColor:foreground,.paragraphStyle:paragraph])
        // Keep source character offsets stable while making paragraph spacing independent of blank lines.
        let emptyParagraph = NSMutableParagraphStyle(); emptyParagraph.minimumLineHeight = 1; emptyParagraph.maximumLineHeight = 1
        let ns = string as NSString
        var searchRange = NSRange(location:0,length:ns.length)
        while searchRange.length > 0 {
            let found = ns.range(of:"\n\n",range:searchRange)
            if found.location == NSNotFound { break }
            attributed.addAttributes([.font:NSFont.systemFont(ofSize:1),.paragraphStyle:emptyParagraph],range:NSRange(location:found.location+1,length:1))
            let next = found.location+found.length; searchRange = NSRange(location:next,length:ns.length-next)
        }
        text.textStorage?.setAttributedString(attributed)
        anchor = character; lastWidth = 0
        changing = false; needsLayout = true; layoutSubtreeIfNeeded(); restore(character)
    }
    func visibleCharacter() -> Int {
        guard let layout = text.layoutManager, let container = text.textContainer, !text.string.isEmpty else { return 0 }
        let point = NSPoint(x: 0, y: max(0, scroll.contentView.bounds.minY - text.textContainerInset.height))
        let glyph = layout.glyphIndex(for: point, in: container)
        return min((text.string as NSString).length-1, layout.characterIndexForGlyph(at: glyph))
    }
    func restore(_ character: Int) {
        guard let layout = text.layoutManager, let container = text.textContainer, !text.string.isEmpty else { return }
        changing = true
        let index = max(0,min(character,(text.string as NSString).length-1))
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: index)
        let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let y = max(0,min(rect.minY + text.textContainerInset.height, text.frame.height-scroll.contentSize.height))
        scroll.contentView.scroll(to: NSPoint(x:0,y:index == 0 ? 0 : y)); scroll.reflectScrolledClipView(scroll.contentView)
        anchor = index; changing = false
    }
    // Return true only if already at the boundary; the caller then changes chapter.
    func page(_ direction: Int) -> Bool {
        let y = scroll.contentView.bounds.minY, maxY = max(0,text.frame.height-scroll.contentSize.height)
        if direction > 0 && y >= maxY-1 { return true }
        if direction < 0 && y <= 1 { return true }
        let next = min(maxY,max(0,y+CGFloat(direction)*max(12,scroll.contentSize.height-24)))
        scroll.contentView.scroll(to: NSPoint(x:0,y:next)); scroll.reflectScrolledClipView(scroll.contentView)
        anchor = visibleCharacter(); didScroll?(); return false
    }
    func goToEnd() {
        scroll.contentView.scroll(to: NSPoint(x:0,y:max(0,text.frame.height-scroll.contentSize.height)))
        scroll.reflectScrolledClipView(scroll.contentView); anchor = visibleCharacter(); didScroll?()
    }
}
