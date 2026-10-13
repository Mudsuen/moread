import AppKit
import ReaderCore

enum ReaderPalette {
    static var dark: Bool { NSAppearance.currentDrawing().bestMatch(from:[.darkAqua,.aqua]) == .darkAqua }
    static var accent: NSColor { dark ? NSColor(white:0.88,alpha:1) : NSColor(white:0.22,alpha:1) }
    static var panel: NSColor { dark ? NSColor(white:0.10,alpha:1) : NSColor(white:0.96,alpha:1) }
    static var card: NSColor { dark ? NSColor(white:1,alpha:0.045) : NSColor(white:1,alpha:0.75) }
}
final class DimmingOverlay: NSView {
    var brightness: Double = 1 { didSet { needsDisplay = true } }
    override func hitTest(_ point:NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.black.withAlphaComponent(1-ContrastMath.exposure(brightness)).setFill(); bounds.fill()
    }
}
final class StyledSegmentCell: NSSegmentedCell {
    override func draw(withFrame frame:NSRect,in controlView:NSView) {
        NSColor(white:ReaderPalette.dark ? 0 : 0.3,alpha:ReaderPalette.dark ? 0.22 : 0.06).setFill()
        NSBezierPath(roundedRect:frame,xRadius:7,yRadius:7).fill()
        let width = frame.width/CGFloat(max(1,segmentCount))
        for index in 0..<segmentCount {
            let rect = NSRect(x:frame.minX+CGFloat(index)*width+2,y:frame.minY+2,width:width-4,height:frame.height-4)
            if isSelected(forSegment:index) { ReaderPalette.accent.setFill(); NSBezierPath(roundedRect:rect,xRadius:5,yRadius:5).fill() }
            let color: NSColor = isSelected(forSegment:index) ? (ReaderPalette.dark ? NSColor(white:0.1,alpha:1) : .white) : .secondaryLabelColor
            let title = label(forSegment:index) ?? "", attributes: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:11,weight:isSelected(forSegment:index) ? .semibold : .regular),.foregroundColor:color]
            let size = (title as NSString).size(withAttributes:attributes)
            (title as NSString).draw(at:NSPoint(x:rect.midX-size.width/2,y:rect.midY-size.height/2),withAttributes:attributes)
        }
    }
}
final class StyledSegment: NSSegmentedControl {
    init(labels:[String],target:AnyObject?,action:Selector?) {
        super.init(frame:.zero); cell = StyledSegmentCell(); segmentCount = labels.count; trackingMode = .selectOne
        for (index,label) in labels.enumerated() { setLabel(label,forSegment:index) }
        segmentDistribution = .fillEqually; self.target = target; self.action = action
        heightAnchor.constraint(equalToConstant:27).isActive = true
    }
    required init?(coder:NSCoder) { fatalError() }
}
final class SettingsCard: NSView {
    let stack = NSStackView()
    override init(frame:NSRect) {
        super.init(frame:frame); wantsLayer = true; layer?.cornerRadius = 11; layer?.borderWidth = 0.5
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9; stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:leadingAnchor,constant:12),stack.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-12),stack.topAnchor.constraint(equalTo:topAnchor,constant:11),stack.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-11)])
        refresh()
    }
    required init?(coder:NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    private func refresh() { layer?.backgroundColor = ReaderPalette.card.cgColor; layer?.borderColor = NSColor(white:ReaderPalette.dark ? 1 : 0,alpha:0.06).cgColor }
}

final class FontPreviewButton: NSButton {
    var fontKey = "system"
    var fontLabel = "系统"
    override func draw(_ dirtyRect:NSRect) {
        let selected = state == .on
        (selected ? ReaderPalette.accent.withAlphaComponent(ReaderPalette.dark ? 0.13 : 0.10) : NSColor.clear).setFill()
        let shape = NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:9,yRadius:9); shape.fill()
        (selected ? ReaderPalette.accent.withAlphaComponent(0.7) : NSColor.labelColor.withAlphaComponent(0.07)).setStroke(); shape.lineWidth = 1; shape.stroke()
        let face: NSFont
        switch fontKey { case "serif": face = NSFont(name:"Songti SC",size:24) ?? .systemFont(ofSize:24); case "kai": face = NSFont(name:"Kaiti SC",size:24) ?? .systemFont(ofSize:24); case "mono": face = .monospacedSystemFont(ofSize:24,weight:.regular); default: face = .systemFont(ofSize:24) }
        let color = selected ? ReaderPalette.accent : NSColor.labelColor
        let preview: [NSAttributedString.Key:Any] = [.font:face,.foregroundColor:color]
        let text = "阅", size = (text as NSString).size(withAttributes:preview)
        (text as NSString).draw(at:NSPoint(x:bounds.midX-size.width/2,y:8),withAttributes:preview)
        let caption: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:10,weight:.medium),.foregroundColor:color.withAlphaComponent(0.8)]
        let captionSize = (fontLabel as NSString).size(withAttributes:caption)
        (fontLabel as NSString).draw(at:NSPoint(x:bounds.midX-captionSize.width/2,y:43),withAttributes:caption)
    }
}

final class MonochromeCheckBox: NSButton {
    init(title:String,target:AnyObject?,action:Selector?) {
        super.init(frame:.zero); setButtonType(.switch); self.title = title; self.target = target; self.action = action; font = .systemFont(ofSize:11); isBordered = false
    }
    required init?(coder:NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width:(title as NSString).size(withAttributes:[.font:font ?? NSFont.systemFont(ofSize:11)]).width+23,height:20) }
    override func draw(_ dirtyRect:NSRect) {
        let box = NSRect(x:1,y:bounds.midY-7,width:14,height:14), path = NSBezierPath(roundedRect:box,xRadius:3,yRadius:3)
        if state == .on {
            ReaderPalette.accent.setFill(); path.fill()
            (ReaderPalette.dark ? NSColor.black : .white).setStroke()
            let tick = NSBezierPath(); tick.move(to:NSPoint(x:box.minX+3,y:box.midY)); tick.line(to:NSPoint(x:box.minX+6,y:box.maxY-3)); tick.line(to:NSPoint(x:box.maxX-3,y:box.minY+3)); tick.lineWidth = 1.5; tick.lineCapStyle = .round; tick.lineJoinStyle = .round; tick.stroke()
        } else { NSColor.secondaryLabelColor.withAlphaComponent(0.7).setStroke(); path.lineWidth = 1; path.stroke() }
        let attributes: [NSAttributedString.Key:Any] = [.font:font ?? NSFont.systemFont(ofSize:11),.foregroundColor:NSColor.labelColor]
        let size = (title as NSString).size(withAttributes:attributes)
        (title as NSString).draw(at:NSPoint(x:23,y:bounds.midY-size.height/2),withAttributes:attributes)
    }
}
final class ReaderRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect:NSRect) {
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect:bounds.insetBy(dx:3,dy:2),xRadius:6,yRadius:6).fill()
    }
}
