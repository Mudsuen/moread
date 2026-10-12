import AppKit
import ReaderCore

if CommandLine.arguments.contains("--verify-book"), let i = CommandLine.arguments.firstIndex(of: "--verify-book"), CommandLine.arguments.count > i+1 {
    do {
        let book = try EPUB.load(directory: URL(fileURLWithPath: CommandLine.arguments[i+1]))
        var characters = 0, nonempty = 0
        for index in book.chapters.indices { do { let text = try book.text(at: index); characters += text.count; if !text.isEmpty { nonempty += 1 } } catch { print("Chapter \(index): \(book.chapters[index].path)"); throw error } }
        print("Verified: \(book.title), \(book.author); \(book.chapters.count) spine entries; \(nonempty) text chapters; \(characters) characters")
        exit(0)
    } catch { fputs("Verification failed: \(error)\n", stderr); exit(1) }
}
let app = NSApplication.shared
MainActor.assumeIsolated {
    let delegate = ReaderApp()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
