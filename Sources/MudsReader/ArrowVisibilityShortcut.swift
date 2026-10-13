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
    var isEnabled: () -> Bool = { true }
    private var chord = ArrowChord()
    private var timer: Timer?
    private var monitor: Any?
    private var pending: NSEvent?
    private var delivery: DispatchWorkItem?
    private var forwarding = false
    private var suppressArrows = false
    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.keyUp]) { [weak self] event in
            guard let self, self.isEnabled(), !self.forwarding, event.keyCode == 123 || event.keyCode == 124 else { return event }
            self.check()
            if self.suppressArrows { return nil }
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
        guard isEnabled() else { chord = ArrowChord(); suppressArrows = false; return }
        let left = CGEventSource.keyState(.combinedSessionState,key:123)
        let right = CGEventSource.keyState(.combinedSessionState,key:124)
        if !left && !right { suppressArrows = false }
        if chord.update(left:left,right:right) {
            delivery?.cancel(); delivery = nil; pending = nil; suppressArrows = true; toggle?()
        }
    }
    private func flush() {
        delivery?.cancel(); delivery = nil
        guard let event = pending else { return }; pending = nil
        forwarding = true; NSApp.sendEvent(event); forwarding = false
    }
    func stop() {
        timer?.invalidate(); timer = nil; delivery?.cancel(); pending = nil
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
    }
}
