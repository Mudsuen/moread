import AppKit

struct ResizeEdges: OptionSet {
    let rawValue: Int
    static let left = Self(rawValue:1), right = Self(rawValue:2), top = Self(rawValue:4), bottom = Self(rawValue:8)
}

// One input surface covers text, line gaps, margins and the empty remainder of a page.
final class StealthInteraction: NSView {
    var turnPage: ((NSEvent) -> Void)?
    var contextMenu: (() -> NSMenu?)?
    var togglePinned: (() -> Void)?
    var toggleVisualVisibility: (() -> Void)?
    var visuallyHidden = false {
        didSet { needsDisplay = true; window?.invalidateCursorRects(for:self); setAccessibilityLabel(visuallyHidden ? "双击恢复阅读" : (pinned ? "取消置顶" : "置顶")) }
    }
    private var pendingPin: DispatchWorkItem?
    var focusText: (() -> Void)?
    var pinned = true { didSet { needsDisplay = true; setAccessibilityLabel(visuallyHidden ? "双击恢复阅读" : (pinned ? "取消置顶" : "置顶")) } }
    private(set) var hovering = false
    var clearBackground = false
    var tintColor = NSColor.white { didSet { needsDisplay = true } }
    private var poll: Timer?
    private var tracking: NSTrackingArea?
    private var mouseMonitor: Any?
    private var pressed: NSEvent?
    private var pressPoint = NSPoint.zero
    private var dragged = false
    private var resizing: ResizeEdges = []
    private var startFrame = NSRect.zero
    private var startScreenPoint = NSPoint.zero
    let edgeWidth: CGFloat = 9
    let cornerWidth: CGFloat = 16
    var pinRect: NSRect { NSRect(x:bounds.midX-17,y:bounds.midY-17,width:34,height:34) }
    override init(frame:NSRect) {
        super.init(frame:frame)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("取消置顶")
        poll = Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] _ in self?.updateHover() }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching:.mouseMoved) { [weak self] _ in self?.updateHover() }
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { pendingPin?.cancel(); poll?.invalidate(); if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) } }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { if visuallyHidden { toggleVisualVisibility?() } else { togglePinned?() }; return true }
    override func hitTest(_ point:NSPoint) -> NSView? { !isHidden && bounds.contains(point) ? self : nil }
    func resizeEdges(at point:NSPoint) -> ResizeEdges {
        let left = point.x <= cornerWidth, right = point.x >= bounds.width-cornerWidth
        let bottom = point.y <= cornerWidth, top = point.y >= bounds.height-cornerWidth
        if left && bottom { return [.left,.bottom] }; if left && top { return [.left,.top] }
        if right && bottom { return [.right,.bottom] }; if right && top { return [.right,.top] }
        if point.x <= edgeWidth { return .left }; if point.x >= bounds.width-edgeWidth { return .right }
        if point.y <= edgeWidth { return .bottom }; if point.y >= bounds.height-edgeWidth { return .top }
        return []
    }
    private func cursor(for edges:ResizeEdges) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position:NSCursor.FrameResizePosition
            switch edges {
            case [.left,.top]: position = .topLeft
            case [.right,.top]: position = .topRight
            case [.left,.bottom]: position = .bottomLeft
            case [.right,.bottom]: position = .bottomRight
            case .left: position = .left
            case .right: position = .right
            case .top: position = .top
            default: position = .bottom
            }
            return .frameResize(position:position,directions:.all)
        }
        if edges == .left || edges == .right { return .resizeLeftRight }
        if edges == .top || edges == .bottom { return .resizeUpDown }
        let symbol = edges == [.left,.top] || edges == [.right,.bottom] ? "arrow.up.left.and.arrow.down.right" : "arrow.up.right.and.arrow.down.left"
        let image = NSImage(systemSymbolName:symbol,accessibilityDescription:nil)!
        return NSCursor(image:image,hotSpot:NSPoint(x:image.size.width/2,y:image.size.height/2))
    }
    override func resetCursorRects() {
        guard !isHidden else { return }
        if visuallyHidden { addCursorRect(bounds,cursor:.arrow); return }
        addCursorRect(bounds,cursor:.openHand); addCursorRect(pinRect,cursor:.pointingHand)
        let w = bounds.width, h = bounds.height, e = edgeWidth, c = cornerWidth
        let regions: [(NSRect,ResizeEdges)] = [
            (NSRect(x:0,y:c,width:e,height:max(0,h-2*c)),.left),(NSRect(x:w-e,y:c,width:e,height:max(0,h-2*c)),.right),
            (NSRect(x:c,y:0,width:max(0,w-2*c),height:e),.bottom),(NSRect(x:c,y:h-e,width:max(0,w-2*c),height:e),.top),
            (NSRect(x:0,y:0,width:c,height:c),[.left,.bottom]),(NSRect(x:w-c,y:0,width:c,height:c),[.right,.bottom]),
            (NSRect(x:0,y:h-c,width:c,height:c),[.left,.top]),(NSRect(x:w-c,y:h-c,width:c,height:c),[.right,.top])]
        for (rect,edges) in regions { addCursorRect(rect,cursor:cursor(for:edges)) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.mouseMoved,.activeAlways,.inVisibleRect],owner:self,userInfo:nil)
        tracking = area; addTrackingArea(area); window?.invalidateCursorRects(for:self)
    }
    override func mouseEntered(with event:NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event:NSEvent) { hovering = false; needsDisplay = true }
    override func mouseMoved(with event:NSEvent) {
        hovering = true; needsDisplay = true
        if visuallyHidden { NSCursor.arrow.set(); return }
        let point = convert(event.locationInWindow,from:nil), edges = resizeEdges(at:convert(event.locationInWindow,from:nil))
        if !edges.isEmpty { cursor(for:edges).set() } else { (pinRect.contains(point) ? NSCursor.pointingHand : .openHand).set() }
    }
    private func updateHover() {
        guard let window, !isHidden, window.isVisible else { if hovering { hovering = false; needsDisplay = true }; return }
        let local = convert(window.convertPoint(fromScreen:NSEvent.mouseLocation),from:nil)
        let next = bounds.contains(local)
        if next != hovering { hovering = next; needsDisplay = true }
    }
    override func draw(_ dirtyRect:NSRect) {
        guard hovering else { return }
        // While hovered, a visually imperceptible hit surface lets WindowServer route drags
        // through otherwise fully transparent pixels. At rest the background is exactly clear.
        if clearBackground || visuallyHidden { NSColor(white:0.5,alpha:0.005).setFill(); bounds.fill() }
        if visuallyHidden { return }
        if let image = NSImage(systemSymbolName:pinned ? "pin.fill" : "pin.slash",accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:13,weight:.medium)) {
            let tint = tintColor.withAlphaComponent(tintColor.alphaComponent*(pinned ? 0.8 : 0.55))
            let rendered = NSImage(size:NSSize(width:16,height:16)); rendered.lockFocus(); tint.set(); image.draw(in:NSRect(x:0,y:0,width:16,height:16)); NSRect(x:0,y:0,width:16,height:16).fill(using:.sourceAtop); rendered.unlockFocus()
            rendered.draw(in:NSRect(x:bounds.midX-8,y:bounds.midY-8,width:16,height:16))
        }
    }
    override func mouseDown(with event:NSEvent) {
        pendingPin?.cancel(); pendingPin = nil
        pressed = event; pressPoint = event.locationInWindow; dragged = false; hovering = true; needsDisplay = true
        resizing = visuallyHidden || event.clickCount > 1 ? [] : resizeEdges(at:convert(event.locationInWindow,from:nil))
        startFrame = window?.frame ?? .zero; startScreenPoint = window?.convertPoint(toScreen:event.locationInWindow) ?? .zero
        focusText?()
    }
    override func mouseDragged(with event:NSEvent) {
        guard !visuallyHidden, pressed != nil, let window else { return }
        let screenPoint = window.convertPoint(toScreen:event.locationInWindow)
        let dx = screenPoint.x-startScreenPoint.x, dy = screenPoint.y-startScreenPoint.y
        guard dragged || hypot(dx,dy) >= 3 else { return }
        dragged = true
        if resizing.isEmpty { window.setFrameOrigin(NSPoint(x:startFrame.minX+dx,y:startFrame.minY+dy)); return }
        var frame = startFrame
        if resizing.contains(.left) { frame.origin.x = min(startFrame.maxX-window.minSize.width,startFrame.minX+dx); frame.size.width = startFrame.maxX-frame.minX }
        if resizing.contains(.right) { frame.size.width = max(window.minSize.width,startFrame.width+dx) }
        if resizing.contains(.bottom) { frame.origin.y = min(startFrame.maxY-window.minSize.height,startFrame.minY+dy); frame.size.height = startFrame.maxY-frame.minY }
        if resizing.contains(.top) { frame.size.height = max(window.minSize.height,startFrame.height+dy) }
        window.setFrame(frame,display:true)
    }
    override func mouseUp(with event:NSEvent) {
        defer { pressed = nil }
        guard pressed != nil, !dragged, hypot(event.locationInWindow.x-pressPoint.x,event.locationInWindow.y-pressPoint.y) < 3 else { return }
        if event.clickCount > 1 && event.clickCount.isMultiple(of:2) { pendingPin?.cancel(); pendingPin = nil; toggleVisualVisibility?(); return }
        guard event.clickCount == 1, !visuallyHidden, resizing.isEmpty,
              pinRect.contains(convert(pressPoint,from:nil)), pinRect.contains(convert(event.locationInWindow,from:nil)) else { return }
        // Wait for the double-click interval so visual hiding never toggles pin as a side effect.
        let action = DispatchWorkItem { [weak self] in self?.togglePinned?() }
        pendingPin = action; DispatchQueue.main.asyncAfter(deadline:.now()+NSEvent.doubleClickInterval,execute:action)
    }
    override func rightMouseDown(with event:NSEvent) { if let menu = contextMenu?() { NSMenu.popUpContextMenu(menu,with:event,for:self) } }
    override func scrollWheel(with event:NSEvent) { if !visuallyHidden { turnPage?(event) } }
}
