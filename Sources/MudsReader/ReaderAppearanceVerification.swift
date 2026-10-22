import AppKit
import ReaderCore

/// An explicit fixture route that never constructs ReaderApp or opens its library,
/// preferences, autosaved windows, global shortcuts or screen-capture service.
enum ReaderAppearanceVerification {
    static func fixtureDirectory(arguments: [String]) throws -> URL {
        guard let flag = arguments.firstIndex(of: "--verify-appearance"),
              arguments.indices.contains(flag + 1), arguments[flag + 1].hasPrefix("/") else {
            throw ReaderError.invalid("Usage: --verify-appearance /absolute/path/to/synthetic-epub-directory")
        }
        return URL(fileURLWithPath: arguments[flag + 1], isDirectory: true).standardizedFileURL
    }

    @MainActor
    static func run(directory: URL) throws -> String {
        let book = try EPUB.load(directory: directory)
        let content = try book.text(at: 0)
        guard !content.isEmpty else { throw ReaderError.invalid("Verification fixture must contain chapter text") }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "moread · Appearance verification"
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for mode in [ReadingMode.paged, .scrolling] {
            let view = ReaderSurface(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
            window.contentView = view
            window.orderFrontRegardless()
            func display(brightness: Double, dark: Bool, opacity: Double, character: Int) {
                view.display(content, fontSize: 11, brightness: brightness, stealth: true, character: character,
                             dark: dark, fontName: "system", lineHeight: 1.15, paragraphSpacing: 3, margin: 48,
                             mode: mode, backgroundOpacity: opacity, textOpacity: 0.8)
                window.displayIfNeeded()
            }
            display(brightness: 1, dark: true, opacity: 1, character: 0)
            view.restore(min(500, content.utf16.count - 1))
            let anchor = view.visibleCharacter(), text = view.text.string, ranges = view.pageRanges
            for step in 1...4 {
                display(brightness: Double(step) / 5, dark: step.isMultiple(of: 2),
                        opacity: Double(step) / 5, character: anchor)
                guard view.visibleCharacter() == anchor, view.text.string == text, view.pageRanges == ranges else {
                    throw ReaderError.invalid("Appearance verification changed chapter text, pagination or reading position")
                }
            }
        }
        return "Verified appearance: 2 reading modes, 8 updates, \(content.utf16.count) UTF-16 characters; text, pages and anchors preserved"
    }
}
