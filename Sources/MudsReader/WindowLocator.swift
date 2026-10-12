import AppKit

final class WindowLocator: NSView {
    private var timer: Timer?
    private var started = Date.distantPast
    override init(frame:NSRect) { super.init(frame:frame); isHidden = true; setAccessibilityElement(false) }
    required init?(coder:NSCoder) { fatalError() }
    deinit { timer?.invalidate() }
    override func hitTest(_ point:NSPoint) -> NSView? { nil }
    func pulse() {
        timer?.invalidate(); started = Date(); isHidden = false; needsDisplay = true
        timer = Timer.scheduledTimer(withTimeInterval:0.05,repeats:true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if Date().timeIntervalSince(self.started) > 1.4 { self.isHidden = true; timer.invalidate(); self.timer = nil }
            else { self.needsDisplay = true }
        }
    }
    override func draw(_ dirtyRect:NSRect) {
        let fraction = min(1,Date().timeIntervalSince(started)/1.4), alpha = 0.35+0.65*sin(fraction * .pi)
        NSColor.black.withAlphaComponent(alpha*0.85).setStroke()
        let outer = NSBezierPath(roundedRect:bounds.insetBy(dx:1.5,dy:1.5),xRadius:7,yRadius:7); outer.lineWidth = 3; outer.stroke()
        NSColor.white.withAlphaComponent(alpha).setStroke()
        let inner = NSBezierPath(roundedRect:bounds.insetBy(dx:3.5,dy:3.5),xRadius:5,yRadius:5); inner.lineWidth = 1.5; inner.stroke()
    }
}
