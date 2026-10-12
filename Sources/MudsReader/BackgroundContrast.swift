import AppKit
import ScreenCaptureKit
import ReaderCore

// Screen pixels remain in memory only. Capture excludes this process and is cropped to the reader.
@MainActor final class BackgroundContrast {
    enum Status: Equatable { case idle, needsPermission, active, unavailable }
    var onLuminance: ((Double) -> Void)?
    var onStatus: ((Status) -> Void)?
    private(set) var status: Status = .idle {
        didSet { if status != oldValue { onStatus?(status) } }
    }
    private weak var window: NSWindow?
    private var timer: Timer?
    private var capturing = false
    private var enabled = false
    private var generation = 0
    private var content: SCShareableContent?
    private var contentDate = Date.distantPast
    func update(window: NSWindow, enabled: Bool) {
        self.window = window; self.enabled = enabled
        guard enabled, window.isVisible, !NSApp.isHidden else { stop(); return }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in Task { @MainActor in await self?.sample() } }
        }
        Task { await sample() }
    }
    func stop() { enabled = false; generation += 1; timer?.invalidate(); timer = nil; status = .idle }
    func requestPermission() {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        if !CGPreflightScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            status = .needsPermission
        } else { content = nil; Task { await sample() } }
    }
    private func sample() async {
        guard enabled, let window, window.isVisible, !NSApp.isHidden else { stop(); return }
        guard !capturing else { return }
        guard CGPreflightScreenCaptureAccess() else { status = .needsPermission; return }
        guard let screen = window.screen,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { status = .unavailable; return }
        capturing = true; defer { capturing = false }
        let token = generation, frame = window.frame
        do {
            if content == nil || Date().timeIntervalSince(contentDate) > 30 {
                content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true); contentDate = Date()
            }
            guard let content, let display = content.displays.first(where:{$0.displayID == displayID}) else { status = .unavailable; return }
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            // Never capture without excluding the reader: that would create color feedback.
            guard !ownApps.isEmpty else { self.content = nil; status = .unavailable; return }
            let filter = SCContentFilter(display:display,excludingApplications:ownApps,exceptingWindows:[])
            let rect = CGRect(x:frame.minX-screen.frame.minX,y:screen.frame.maxY-frame.maxY,width:frame.width,height:frame.height)
                .intersection(CGRect(origin:.zero,size:screen.frame.size))
            guard rect.width > 1, rect.height > 1 else { return }
            let config = SCStreamConfiguration(); config.sourceRect = rect
            config.width = max(2,Int(rect.width/2)); config.height = max(2,Int(rect.height/2))
            config.showsCursor = false; config.capturesAudio = false
            let image = try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
            guard token == generation, enabled, window.isVisible, window.frame == frame else { return }
            guard let luminance = Self.luminance(of:image) else { status = .unavailable; return }
            onLuminance?(luminance); status = .active
        } catch { if token == generation { content = nil; status = .unavailable } }
    }
    nonisolated static func luminance(of image: CGImage) -> Double? {
        var pixels = [UInt8](repeating:0,count:32*32*4)
        let luminance: Double? = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data:buffer.baseAddress,width:32,height:32,bitsPerComponent:8,bytesPerRow:32*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(image,in:CGRect(x:0,y:0,width:32,height:32))
            let data = buffer.bindMemory(to:UInt8.self)
            var total = 0.0
            for i in stride(from:0,to:data.count,by:4) {
                total += 0.2126*ContrastMath.linear(Double(data[i])/255)+0.7152*ContrastMath.linear(Double(data[i+1])/255)+0.0722*ContrastMath.linear(Double(data[i+2])/255)
            }
            return total/1024
        }
        return luminance
    }
}
