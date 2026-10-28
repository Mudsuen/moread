import AppKit

struct ArrowChord {
    private var latched = false
    mutating func update(left:Bool,right:Bool) -> Bool {
        if !left && !right { latched = false }
        guard left && right && !latched else { return false }
        latched = true; return true
    }
}

@MainActor final class ArrowVisibilityShortcut {
    var toggle: (() -> Void)?
    var canNavigate: () -> Bool = { true }
    var isEnabled: () -> Bool = { true }
    private var chord = ArrowChord()
    private var timer: Timer?
    private var monitor: Any?
    private var pending: NSEvent?
    private var delivery: DispatchWorkItem?
    private var forwarding = false
    private var suppressArrows = false
    private var localLeft = false
    private var localRight = false
    func start() {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.keyUp]) { [weak self] event in
            guard let self, self.isEnabled(), !self.forwarding, event.keyCode == 123 || event.keyCode == 124 else { return event }
            if event.keyCode == 123 { self.localLeft = event.type == .keyDown }
            else { self.localRight = event.type == .keyDown }
            self.check(left:self.localLeft,right:self.localRight)
            if self.suppressArrows { return nil }
            guard self.canNavigate() else { return event }
            guard event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty else { return event }
            if event.type == .keyUp { self.flush(); return event }
            if event.isARepeat { return event }
            self.flush(); self.pending = event
            let work = DispatchWorkItem { [weak self] in self?.flush() }
            self.delivery = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.12,execute:work)
            return nil
        }
        let t = Timer(timeInterval:0.03,repeats:true) { [weak self] _ in Task { @MainActor in self?.check() } }
        timer = t; RunLoop.main.add(t,forMode:.common)
    }
    private func check() {
        // Session state can exclude arrow events swallowed by our local monitor.
        // Use delivered events while focused, and physical HID state elsewhere.
        if NSApp.isActive { check(left:localLeft,right:localRight); return }
        localLeft = false; localRight = false
        check(left:CGEventSource.keyState(.hidSystemState,key:123),
              right:CGEventSource.keyState(.hidSystemState,key:124))
    }
    func check(left:Bool,right:Bool) {
        guard isEnabled() else { chord = ArrowChord(); suppressArrows = false; return }
        if !left && !right { suppressArrows = false }
        if chord.update(left:left,right:right) {
            delivery?.cancel(); delivery = nil; pending = nil; suppressArrows = true; toggle?()
        }
    }
    private func flush() {
        delivery?.cancel(); delivery = nil
        guard let event = pending else { return }; pending = nil
        guard canNavigate() else { return }
        forwarding = true; NSApp.sendEvent(event); forwarding = false
    }
    func cancelPending() { delivery?.cancel(); delivery = nil; pending = nil }
    func stop() {
        timer?.invalidate(); timer = nil; delivery?.cancel(); pending = nil
        localLeft = false; localRight = false; chord = ArrowChord(); suppressArrows = false
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
    }
}
