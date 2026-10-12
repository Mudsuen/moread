import AppKit

struct HoverToolbarGeometry {
    static func diameter(fontSize:CGFloat) -> CGFloat { fontSize * 1.5 }
    static func buttonFrame(index:Int,fontSize:CGFloat) -> NSRect {
        let diameter = diameter(fontSize:fontSize), gap = max(3,fontSize * 0.4)
        return NSRect(x:2 + CGFloat(index) * (diameter + gap),y:2,width:diameter,height:diameter)
    }
    static func size(fontSize:CGFloat) -> NSSize {
        NSSize(width:buttonFrame(index:2,fontSize:fontSize).maxX + 2,height:diameter(fontSize:fontSize) + 4)
    }
    static func frame(reader:NSRect,screen:NSRect,fontSize:CGFloat = 9,textTop:CGFloat? = nil) -> NSRect {
        let gap: CGFloat = 1, size = Self.size(fontSize:fontSize)
        // Place visible symbols beside the first text line, rather than stacking
        // the toolbar's padding on top of the reader's transparent top margin.
        let symbolBottom = 2 + diameter(fontSize:fontSize) * (1-0.58)/2
        let bottom = textTop.map { $0 + 2 - symbolBottom } ?? reader.maxY+gap
        let above = NSRect(x:max(screen.minX,min(reader.minX+2,screen.maxX-size.width)),y:bottom,width:size.width,height:size.height)
        if screen.contains(above) { return above }
        let left = NSRect(x:reader.minX-gap-size.width,y:min(reader.maxY,screen.maxY)-size.height,width:size.width,height:size.height)
        if screen.contains(left) { return left }
        return NSRect(x:max(screen.minX,min(reader.minX+2,screen.maxX-size.width)),y:max(screen.minY,min(reader.minY-gap-size.height,screen.maxY-size.height)),width:size.width,height:size.height)
    }
    static func contains(_ point:NSPoint,reader:NSRect,toolbar:NSRect) -> Bool {
        if reader.contains(point) || toolbar.contains(point) { return true }
        if toolbar.minY >= reader.maxY { return NSRect(x:toolbar.minX,y:reader.maxY,width:toolbar.width,height:toolbar.minY-reader.maxY).contains(point) }
        if toolbar.maxX <= reader.minX { return NSRect(x:toolbar.maxX,y:toolbar.minY,width:reader.minX-toolbar.maxX,height:toolbar.height).contains(point) }
        return NSRect(x:toolbar.minX,y:toolbar.maxY,width:toolbar.width,height:max(0,reader.minY-toolbar.maxY)).contains(point)
    }
}
struct HoverVisibility {
    private var lastInside = Date.distantPast
    mutating func visible(inside:Bool,now:Date) -> Bool {
        if inside { lastInside = now }
        return inside || now.timeIntervalSince(lastInside) < 0.18
    }
    mutating func reset() { lastInside = .distantPast }
}
private final class HoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class TransparentToolbarView: NSView {
    override func draw(_ rect:NSRect) { NSColor(white:0.5,alpha:0.005).setFill(); bounds.fill() }
}
final class FloatingCircleButton: NSButton {
    var symbol = "list.bullet" { didSet { needsDisplay = true } }
    var foreground = NSColor.labelColor { didSet { needsDisplay = true } }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.pointingHand) }
    override func draw(_ dirtyRect:NSRect) {
        let circle = NSBezierPath(ovalIn:bounds)
        if isHighlighted { foreground.withAlphaComponent(0.12).setFill(); circle.fill() }
        let glyphSize = bounds.width * 0.58
        if let image = NSImage(systemSymbolName:symbol,accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:glyphSize,weight:.medium)) {
            let rect = NSRect(x:0,y:0,width:glyphSize,height:glyphSize)
            let glyph = NSImage(size:rect.size); glyph.lockFocus(); image.draw(in:rect)
            foreground.withAlphaComponent(0.9).setFill(); rect.fill(using:.sourceAtop); glyph.unlockFocus()
            glyph.draw(in:NSRect(x:bounds.midX-glyphSize/2,y:bounds.midY-glyphSize/2,width:glyphSize,height:glyphSize))
        }
    }
}
@MainActor final class HoverToolbar: NSObject {
    let panel: NSPanel
    let buttons: [FloatingCircleButton]
    weak var reader: NSWindow?
    var textTop: (() -> CGFloat?)?
    var onContents: (() -> Void)?
    var onSettings: (() -> Void)?
    var onPin: (() -> Void)?
    private var timer: Timer?
    private var visibility = HoverVisibility()
    private var enabled = false
    private var fontSize: CGFloat = 9
    init(reader:NSWindow) {
        self.reader = reader
        panel = HoverPanel(contentRect:NSRect(origin:.zero,size:HoverToolbarGeometry.size(fontSize:9)),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.title = "moread · 阅读工具"; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
        let root = TransparentToolbarView(frame:NSRect(origin:.zero,size:HoverToolbarGeometry.size(fontSize:9))); panel.contentView = root
        buttons = (0..<3).map { index in
            let b = FloatingCircleButton(frame:HoverToolbarGeometry.buttonFrame(index:index,fontSize:9)); b.isBordered = false; b.title = ""; b.tag = index; root.addSubview(b); return b
        }
        super.init()
        for (index,b) in buttons.enumerated() {
            b.symbol = ["list.bullet","textformat.size","pin.fill"][index]
            b.target = self; b.action = #selector(activate(_:)); b.toolTip = ["目录 ⌘F","格式设置 ⌘,","取消置顶"][index]; b.setAccessibilityLabel(["目录","格式设置","取消置顶"][index])
        }
    }
    func update(enabled:Bool,pinned:Bool,tint:NSColor,fontSize:CGFloat = 9) {
        self.enabled = enabled
        self.fontSize = fontSize
        for (index,button) in buttons.enumerated() {
            button.frame = HoverToolbarGeometry.buttonFrame(index:index,fontSize:fontSize)
            button.needsDisplay = true
        }
        buttons[2].symbol = pinned ? "pin.fill" : "pin"
        buttons[2].toolTip = pinned ? "取消置顶" : "置顶"; buttons[2].setAccessibilityLabel(pinned ? "取消置顶" : "置顶")
        for b in buttons { b.foreground = tint.withAlphaComponent(1) }
        guard enabled else { stop(); return }
        if timer == nil {
            let t = Timer(timeInterval:0.08,repeats:true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
            timer = t; RunLoop.main.add(t,forMode:.common)
        }
        refresh()
    }
    func stop() { enabled = false; timer?.invalidate(); timer = nil; visibility.reset(); hide() }
    private func hide() { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
    func refresh() {
        guard enabled, let reader, reader.isVisible, !NSApp.isHidden, reader.occlusionState.contains(.visible), let screen = reader.screen else { hide(); visibility.reset(); return }
        let frame = HoverToolbarGeometry.frame(reader:reader.frame,screen:screen.visibleFrame,fontSize:fontSize,textTop:textTop?())
        if panel.frame != frame { panel.setFrame(frame,display:true) }
        panel.level = reader.level
        let inside = HoverToolbarGeometry.contains(NSEvent.mouseLocation,reader:reader.frame,toolbar:frame)
        if visibility.visible(inside:inside,now:Date()) {
            if panel.parent !== reader { reader.addChildWindow(panel,ordered:.above) }
            if !panel.isVisible { panel.orderFront(nil) }
        } else { hide() }
    }
    @objc private func activate(_ sender:NSButton) {
        switch sender.tag { case 0: onContents?(); case 1: onSettings?(); default: onPin?() }
    }
}
