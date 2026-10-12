import AppKit
import ScreenCaptureKit
import ReaderCore

struct BackgroundSample {
    let windowFrame: NSRect
    let captureFrame: NSRect
    let width: Int
    let height: Int
    let luminance: [Double]
    var median: Double { let sorted = luminance.sorted(); return sorted[sorted.count/2] }
    // Screen coordinates are bottom-up; captured pixel rows are top-down.
    func background(under rect:NSRect) -> Double? {
        let region = rect.intersection(captureFrame)
        guard !region.isEmpty else { return nil }
        let x0 = max(0,Int((region.minX-captureFrame.minX)/captureFrame.width*Double(width)))
        let x1 = min(width,Int(ceil((region.maxX-captureFrame.minX)/captureFrame.width*Double(width))))
        let y0 = max(0,Int((captureFrame.maxY-region.maxY)/captureFrame.height*Double(height)))
        let y1 = min(height,Int(ceil((captureFrame.maxY-region.minY)/captureFrame.height*Double(height))))
        guard x0 < x1, y0 < y1 else { return nil }
        var local: [Double] = []
        for y in y0..<y1 { local.append(contentsOf:luminance[(y*width+x0)..<(y*width+x1)]) }
        local.sort()
        return local[local.count/2]
    }
}

// Screen pixels remain in memory only. Capture excludes this process and is cropped to the reader.
@MainActor final class BackgroundContrast {
    enum Status: Equatable { case idle, needsPermission, active, unavailable }
    var onSample: ((BackgroundSample) -> Void)?
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
            let t = Timer(timeInterval:0.2,repeats:true) { [weak self] _ in Task { @MainActor in await self?.sample() } }
            timer = t; RunLoop.main.add(t,forMode:.common)
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
        let sampledFrame = window.frame
        capturing = true
        defer {
            capturing = false
            // A move during the asynchronous capture invalidates that image. Resample the
            // current position immediately, rather than waiting for another timer tick.
            if enabled, window.isVisible, window.frame != sampledFrame { Task { await sample() } }
        }
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
            let scale = min(1,720/rect.width,480/rect.height)
            config.width = max(2,Int(rect.width*scale)); config.height = max(2,Int(rect.height*scale))
            config.showsCursor = false; config.capturesAudio = false
            let image = try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
            guard token == generation, enabled, window.isVisible, window.frame == frame else { return }
            let captureFrame = NSRect(x:screen.frame.minX+rect.minX,y:screen.frame.maxY-rect.maxY,width:rect.width,height:rect.height)
            guard let sample = Self.sample(of:image,windowFrame:frame,captureFrame:captureFrame) else { status = .unavailable; return }
            status = .active; onSample?(sample)
        } catch { if token == generation { content = nil; status = .unavailable } }
    }
    nonisolated static func sample(of image:CGImage,windowFrame:NSRect,captureFrame:NSRect) -> BackgroundSample? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating:0,count:width*height*4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
            let data = buffer.bindMemory(to:UInt8.self)
            var values: [Double] = []; values.reserveCapacity(width*height)
            for i in stride(from:0,to:data.count,by:4) {
                // A transparent capture is missing data, not a black desktop.
                guard data[i+3] >= 250 else { return nil }
                values.append(0.2126*ContrastMath.linear(Double(data[i])/255)+0.7152*ContrastMath.linear(Double(data[i+1])/255)+0.0722*ContrastMath.linear(Double(data[i+2])/255))
            }
            return BackgroundSample(windowFrame:windowFrame,captureFrame:captureFrame,width:width,height:height,luminance:values)
        }
    }
    nonisolated static func luminance(of image:CGImage) -> Double? {
        let frame = NSRect(x:0,y:0,width:image.width,height:image.height)
        return sample(of:image,windowFrame:frame,captureFrame:frame)?.median
    }
}
