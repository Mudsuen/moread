import AppKit
import ReaderCore

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
        if stealth { window?.performDrag(with:event) } else { super.mouseDown(with:event) }
    }
}
final class StealthWindow: NSWindow {
    @discardableResult func restoreSavedGeometry(named name:String) -> Bool { setFrameUsingName(name,force:true) }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ReadingScrollView: NSScrollView {
    var canNavigate: () -> Bool = { true }
    var paged = true
    var turnPage: ((Int) -> Void)?
    private var accumulated: CGFloat = 0
    private var gestureTurned = false
    private var lastWheelTurn: TimeInterval = -.infinity
    override func scrollWheel(with event: NSEvent) {
        guard canNavigate() else { return }
        guard paged else { super.scrollWheel(with:event); return }
        // A trackpad gesture advances once; inertial events must not skip more pages.
        if !event.momentumPhase.isEmpty { return }
        if event.phase.contains(.began) { accumulated = 0; gestureTurned = false }
        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        if !event.phase.isEmpty {
            accumulated += delta
            if !gestureTurned, abs(accumulated) >= 12 { gestureTurned = true; turnPage?(accumulated < 0 ? 1 : -1) }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { accumulated = 0; gestureTurned = false }
        } else if abs(delta) > 0.01, event.timestamp-lastWheelTurn >= 0.18 {
            lastWheelTurn = event.timestamp; turnPage?(delta < 0 ? 1 : -1)
        }
    }
}

final class ReaderSurface: NSView {
    let scroll = ReadingScrollView()
    let text = ReadingTextView()
    let interaction = StealthInteraction(frame:.zero)
    let locator = WindowLocator(frame:.zero)
    let previousPageButton = FloatingCircleButton(frame:.zero)
    let nextPageButton = FloatingCircleButton(frame:.zero)
    var toggleVisualVisibility: (() -> Void)?
    private(set) var visuallyHidden = false
    private var readingBackground: CGColor?
    private(set) var foregroundColor = NSColor.labelColor
    private var textOpacity = 1.0
    private var exposure = 1.0
    private var baseWhite = 0.96
    private var adaptiveWhite: Bool?
    private var backgroundSample: BackgroundSample?
    private var adaptiveEnabled = false
    private var brightness = 1.0
    private var backgroundOpacity = 1.0
    private var panelLuminance = 0.0
    var didScroll: (() -> Void)?
    private var observer: NSObjectProtocol?
    private var lastSize = NSSize.zero
    private var changing = false
    private var source = NSAttributedString(string:"")
    private var layoutInputs: ReaderLayoutInputs?
    private(set) var pageRanges: [NSRange] = []
    private(set) var pageIndex = 0
    private(set) var mode: ReadingMode = .paged
    var displayedRange: NSRange { mode == .paged ? (pageRanges.indices.contains(pageIndex) ? pageRanges[pageIndex] : NSRange(location:0,length:0)) : NSRange(location:0,length:source.length) }
    var anchor = 0
    var stealth = false
    private var readingMargin: Double = 48
    override init(frame:NSRect) {
        super.init(frame:frame); wantsLayer = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        text.isEditable = false; text.isSelectable = true; text.isRichText = false; text.drawsBackground = false
        text.isHorizontallyResizable = false; text.isVerticallyResizable = true
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.textContainer?.lineFragmentPadding = 0
        scroll.documentView = text; addSubview(scroll); addSubview(interaction); addSubview(locator)
        for (button,direction,label,symbol) in [(previousPageButton,-1,"上一页","chevron.left"),(nextPageButton,1,"下一页","chevron.right")] {
            button.title = ""; button.isBordered = false; button.symbol = symbol
            button.tag = direction; button.target = self; button.action = #selector(clickPage(_:))
            button.toolTip = label; button.setAccessibilityLabel(label); button.isHidden = true
            addSubview(button)
        }
        interaction.isHidden = true
        interaction.contextMenu = { [weak self] in self?.text.menu }
        interaction.turnPage = { [weak self] in self?.scroll.scrollWheel(with:$0) }
        interaction.focusText = { [weak self] in guard let self else { return }; self.window?.makeKeyAndOrderFront(nil); self.window?.makeFirstResponder(self.text) }
        interaction.toggleVisualVisibility = { [weak self] in self?.toggleVisualVisibility?() }
        scroll.turnPage = { [weak self] in self?.text.turnPage?($0) }
        scroll.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:scroll.contentView,queue:.main) { [weak self] _ in
            guard let self, !self.changing, self.mode == .scrolling else { return }
            self.anchor = self.visibleCharacter(); self.applyUniformContrast(); self.didScroll?()
        }
        setAccessibilityLabel("阅读正文"); text.setAccessibilityLabel("阅读正文")
    }
    @objc private func clickPage(_ sender:NSButton) {
        guard !visuallyHidden, source.length > 0, scroll.canNavigate() else { return }
        text.turnPage?(sender.tag)
    }
    private func updatePageButtons() {
        for button in [previousPageButton,nextPageButton] {
            button.isHidden = visuallyHidden || source.length == 0
            button.foreground = foregroundColor
            button.alphaValue = foregroundColor.alphaComponent
        }
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    override func layout() {
        let oldAnchor = anchor
        changing = true
        super.layout(); scroll.frame = bounds; interaction.frame = bounds; locator.frame = bounds
        let size = scroll.contentSize
        // Leave the outer 9 points available for compact-window resizing.
        let buttonHeight = min(32,max(0,bounds.height-32))
        previousPageButton.frame = NSRect(x:10,y:(bounds.height-buttonHeight)/2,width:18,height:buttonHeight)
        nextPageButton.frame = NSRect(x:bounds.width-28,y:(bounds.height-buttonHeight)/2,width:18,height:buttonHeight)
        text.textContainerInset.width = stealth ? 32 : max(32,min(readingMargin,max(16,size.width*0.16)))
        text.frame.size.width = max(20,size.width)
        text.textContainer?.containerSize = NSSize(width:max(10,size.width-text.textContainerInset.width*2),height:.greatestFiniteMagnitude)
        if lastSize != size {
            lastSize = size
            if mode == .paged { paginate(anchoredAt:oldAnchor); showPage(containing:oldAnchor) }
            else { updateDocumentHeight(); restore(oldAnchor) }
        } else if mode == .scrolling { updateDocumentHeight() }
        changing = false
        applyUniformContrast()
    }
    private func updateDocumentHeight() {
        guard let layout = text.layoutManager, let container = text.textContainer else { return }
        layout.ensureLayout(for:container)
        text.frame.size.height = max(scroll.contentSize.height,layout.usedRect(for:container).height+text.textContainerInset.height*2+8)
    }
    func display(_ string:String,fontSize:CGFloat,brightness:Double,stealth:Bool,character:Int,dark:Bool,fontName:String,lineHeight:Double,paragraphSpacing:Double,margin:Double,mode:ReadingMode = .paged,backgroundOpacity:Double = 1,textOpacity:Double = 1,adaptiveText:Bool = false) {
        let inputs = ReaderLayoutInputs(text:string,fontSize:fontSize,stealth:stealth,fontName:fontName,
                                        lineHeight:lineHeight,paragraphSpacing:paragraphSpacing,margin:margin,mode:mode)
        changing = true; self.textOpacity = textOpacity; exposure = stealth ? ContrastMath.exposure(brightness) : 1
        self.brightness = brightness; self.backgroundOpacity = backgroundOpacity
        adaptiveEnabled = adaptiveText && stealth && backgroundOpacity < 1
        panelLuminance = ContrastMath.linear((dark ? 0.025 : 0.97)*exposure)
        if !adaptiveEnabled { backgroundSample = nil }
        baseWhite = dark ? 0.96 : 0.12
        if !adaptiveText || !stealth || backgroundOpacity >= 1 { adaptiveWhite = nil }
        interaction.clearBackground = backgroundOpacity == 0
        let background = stealth ? NSColor(white:(dark ? 0.025 : 0.97)*exposure,alpha:backgroundOpacity) : (dark ? .black : NSColor(white:0.97,alpha:1))
        let foreground = stealth ? NSColor(white:(adaptiveWhite.map { $0 ? 0.98 : 0.06 } ?? baseWhite),alpha:ContrastMath.textAlpha(brightness:brightness,opacity:textOpacity)) : (dark ? NSColor(calibratedWhite:0.92,alpha:1) : NSColor(white:0.18,alpha:1))
        readingBackground = background.cgColor
        layer?.backgroundColor = visuallyHidden ? NSColor.clear.cgColor : readingBackground
        if layoutInputs == inputs, character == visibleCharacter() {
            // Color and opacity do not change glyph geometry. Preserve pagination,
            // the reading anchor and selection instead of replacing the chapter.
            updateForegroundColor(foreground)
            changing = false
            layoutSubtreeIfNeeded()
            applyUniformContrast()
            return
        }
        layoutInputs = inputs
        self.mode = mode; self.stealth = stealth; text.stealth = stealth; readingMargin = margin
        interaction.isHidden = !stealth
        scroll.paged = mode == .paged; scroll.hasVerticalScroller = !stealth && mode == .scrolling
        text.isSelectable = !stealth; text.isVerticallyResizable = mode == .scrolling
        text.textContainerInset = NSSize(width:stealth ? 10 : margin,height:stealth ? 7 : 24)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineHeightMultiple = lineHeight; paragraph.paragraphSpacing = paragraphSpacing; paragraph.lineBreakMode = .byWordWrapping
        let font: NSFont
        switch fontName { case "serif": font = NSFont(name:"Songti SC",size:fontSize) ?? .systemFont(ofSize:fontSize); case "kai": font = NSFont(name:"Kaiti SC",size:fontSize) ?? .systemFont(ofSize:fontSize); case "mono": font = .monospacedSystemFont(ofSize:fontSize,weight:.regular); default: font = .systemFont(ofSize:fontSize) }
        foregroundColor = foreground
        let attributed = NSMutableAttributedString(string:string,attributes:[.font:font,.foregroundColor:foreground,.paragraphStyle:paragraph])
        // Keep UTF-16 offsets stable while making paragraph spacing independent of blank lines.
        let empty = NSMutableParagraphStyle(); empty.minimumLineHeight = 1; empty.maximumLineHeight = 1
        let ns = string as NSString; var remaining = NSRange(location:0,length:ns.length)
        while remaining.length > 0 {
            let found = ns.range(of:"\n\n",range:remaining); if found.location == NSNotFound { break }
            attributed.addAttributes([.font:NSFont.systemFont(ofSize:1),.paragraphStyle:empty],range:NSRange(location:found.location+1,length:1))
            let next = NSMaxRange(found); remaining = NSRange(location:next,length:ns.length-next)
        }
        source = attributed
        updatePageButtons()
        if mode == .scrolling { text.textStorage?.setAttributedString(source) }
        anchor = character; lastSize = .zero
        changing = false; needsLayout = true; layoutSubtreeIfNeeded(); restore(character)
    }
    private func paginate(anchoredAt character:Int) {
        pageRanges = []
        guard source.length > 0 else { return }
        let raw = min(max(0,character),source.length-1)
        let fixedStart = (source.string as NSString).rangeOfComposedCharacterSequence(at:raw).location
        let size = NSSize(width:max(10,scroll.contentSize.width-text.textContainerInset.width*2),height:max(1,scroll.contentSize.height-text.textContainerInset.height*2))
        // Make the current first character an explicit page boundary. Resizing never pulls
        // earlier text into the current page; prefix/suffix still cover the source exactly once.
        for part in [NSRange(location:0,length:fixedStart),NSRange(location:fixedStart,length:source.length-fixedStart)] where part.length > 0 {
            let storage = NSTextStorage(attributedString:source.attributedSubstring(from:part)), layout = NSLayoutManager()
            storage.addLayoutManager(layout)
            var end = 0
            while end < part.length {
                let container = NSTextContainer(containerSize:size); container.lineFragmentPadding = 0; layout.addTextContainer(container)
                layout.ensureLayout(for:container)
                let glyphs = layout.glyphRange(for:container)
                guard glyphs.length > 0 else { break }
                let range = layout.characterRange(forGlyphRange:glyphs,actualGlyphRange:nil)
                guard NSMaxRange(range) > end else { break }
                pageRanges.append(NSRange(location:part.location+end,length:NSMaxRange(range)-end)); end = NSMaxRange(range)
            }
        }
    }
    private func showPage(containing character:Int) {
        guard !pageRanges.isEmpty else { anchor = character; return }
        let index = min(max(0,character),max(0,source.length-1))
        pageIndex = pageRanges.firstIndex(where:{ NSLocationInRange(index,$0) }) ?? max(0,pageRanges.count-1)
        showCurrentPage()
    }
    private func showCurrentPage() {
        let wasChanging = changing; changing = true
        let range = displayedRange
        text.textStorage?.setAttributedString(source.attributedSubstring(from:range))
        text.frame.size.height = scroll.contentSize.height
        text.layoutManager?.ensureLayout(for:text.textContainer!)
        scroll.contentView.scroll(to:.zero); scroll.reflectScrolledClipView(scroll.contentView)
        anchor = range.location; changing = wasChanging
        applyUniformContrast()
    }
    func visibleTextTopOnScreen() -> CGFloat? {
        guard let window, let layout = text.layoutManager, let container = text.textContainer else { return nil }
        layout.ensureLayout(for:container)
        let origin = text.textContainerOrigin, visible = text.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect:visible.offsetBy(dx:-origin.x,dy:-origin.y),in:container)
        let string = text.string as NSString
        for glyph in glyphs.location..<NSMaxRange(glyphs) {
            let range = layout.characterRange(forGlyphRange:NSRange(location:glyph,length:1),actualGlyphRange:nil)
            guard NSMaxRange(range) <= string.length,
                  !string.substring(with:range).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { continue }
            let rect = layout.boundingRect(forGlyphRange:NSRange(location:glyph,length:1),in:container).offsetBy(dx:origin.x,dy:origin.y).intersection(visible)
            if !rect.isEmpty { return window.convertToScreen(text.convert(rect,to:nil)).maxY }
        }
        return nil
    }
    func setVisualHidden(_ hidden:Bool) {
        visuallyHidden = hidden
        scroll.alphaValue = hidden ? 0 : 1
        layer?.backgroundColor = hidden ? NSColor.clear.cgColor : readingBackground
        interaction.visuallyHidden = hidden
        updatePageButtons()
        if hidden { locator.cancel() }
    }
    func applyAdaptiveColor(_ prefersWhite:Bool?) {
        guard stealth, adaptiveWhite != prefersWhite else { return }
        adaptiveWhite = prefersWhite
        let color = NSColor(white:(prefersWhite.map { $0 ? 0.98 : 0.06 } ?? baseWhite),alpha:ContrastMath.textAlpha(brightness:brightness,opacity:textOpacity))
        updateForegroundColor(color)
    }
    private func updateForegroundColor(_ color: NSColor) {
        guard foregroundColor != color else { return }
        foregroundColor = color
        updatePageButtons()
        let updated = NSMutableAttributedString(attributedString:source)
        updated.addAttribute(.foregroundColor,value:color,range:NSRange(location:0,length:updated.length)); source = updated
        text.textStorage?.addAttribute(.foregroundColor,value:color,range:NSRange(location:0,length:(text.string as NSString).length))
    }
    func applyBackgroundSample(_ sample:BackgroundSample?) {
        backgroundSample = sample
        adaptiveEnabled = sample != nil && stealth && backgroundOpacity < 1
        applyUniformContrast()
    }
    private func applyUniformContrast() {
        guard adaptiveEnabled, !visuallyHidden, let sample = backgroundSample,
              let window, sample.windowFrame == window.frame else { return }
        let background = sample.median*(1-backgroundOpacity)+panelLuminance*backgroundOpacity
        applyAdaptiveColor(ContrastMath.prefersWhite(backgroundLuminance:background,brightness:brightness,textOpacity:textOpacity,previous:adaptiveWhite))
    }
    func visibleCharacter() -> Int {
        if mode == .paged { return displayedRange.location }
        guard let layout = text.layoutManager, let container = text.textContainer, !text.string.isEmpty else { return 0 }
        let point = NSPoint(x:0,y:max(0,scroll.contentView.bounds.minY-text.textContainerInset.height))
        let glyph = layout.glyphIndex(for:point,in:container)
        return min((text.string as NSString).length-1,layout.characterIndexForGlyph(at:glyph))
    }
    func restore(_ character:Int) {
        if mode == .paged { showPage(containing:character); return }
        guard let layout = text.layoutManager, let container = text.textContainer, !text.string.isEmpty else { return }
        let wasChanging = changing; changing = true
        let index = max(0,min(character,(text.string as NSString).length-1)); layout.ensureLayout(for:container)
        let rect = layout.lineFragmentRect(forGlyphAt:layout.glyphIndexForCharacter(at:index),effectiveRange:nil)
        let y = max(0,min(rect.minY+text.textContainerInset.height,text.frame.height-scroll.contentSize.height))
        scroll.contentView.scroll(to:NSPoint(x:0,y:index == 0 ? 0 : y)); scroll.reflectScrolledClipView(scroll.contentView)
        anchor = index; changing = wasChanging
    }
    // Return true only at a chapter boundary. A short final page is never backfilled.
    func page(_ direction:Int) -> Bool {
        if mode == .paged {
            let next = pageIndex+direction
            guard pageRanges.indices.contains(next) else { return true }
            pageIndex = next; showCurrentPage(); didScroll?(); return false
        }
        let y = scroll.contentView.bounds.minY, maxY = max(0,text.frame.height-scroll.contentSize.height)
        if direction > 0 && y >= maxY-1 { return true }
        if direction < 0 && y <= 1 { return true }
        let next = min(maxY,max(0,y+CGFloat(direction)*scroll.contentSize.height))
        scroll.contentView.scroll(to:NSPoint(x:0,y:next)); scroll.reflectScrolledClipView(scroll.contentView)
        anchor = visibleCharacter(); didScroll?(); return false
    }
    func goToEnd() {
        if mode == .paged { pageIndex = max(0,pageRanges.count-1); showCurrentPage(); didScroll?(); return }
        scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,text.frame.height-scroll.contentSize.height)))
        scroll.reflectScrolledClipView(scroll.contentView); anchor = visibleCharacter(); didScroll?()
    }
}

private struct ReaderLayoutInputs: Equatable {
    var text: String
    var fontSize: CGFloat
    var stealth: Bool
    var fontName: String
    var lineHeight: Double
    var paragraphSpacing: Double
    var margin: Double
    var mode: ReadingMode

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.fontSize == rhs.fontSize && lhs.stealth == rhs.stealth && lhs.fontName == rhs.fontName
            && lhs.lineHeight == rhs.lineHeight && lhs.paragraphSpacing == rhs.paragraphSpacing
            && lhs.margin == rhs.margin && lhs.mode == rhs.mode
            // Swift String equality folds canonically equivalent spellings; the reader
            // must preserve the exact source sequence and its UTF-16 reading offsets.
            && lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }
}
