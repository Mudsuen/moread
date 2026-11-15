import Foundation

public struct Chapter: Codable, Equatable, Sendable {
    public let title: String
    public let path: String
}
public struct Book: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public let title: String
    public let author: String
    public let chapters: [Chapter]
    public var directory: String
    public let cover: String?
    public func text(at index: Int) throws -> String {
        guard chapters.indices.contains(index) else { throw ReaderError.invalid("章节不存在") }
        let url = try EPUB.safeURL(chapters[index].path, under: URL(fileURLWithPath: directory))
        return try EPUB.plainText(Data(contentsOf: url))
    }
}
public enum ReaderError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(s) = self { return s }; return nil }
}
final class XML: NSObject, XMLParserDelegate {
    var start: ((String, [String:String]) -> Void)?
    var end: ((String) -> Void)?
    var text: ((String) -> Void)?
    private func cancelled(_ parser: XMLParser) -> Bool { if Task.isCancelled { parser.abortParsing(); return true }; return false }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) { if !cancelled(parser) { start?(name.components(separatedBy: ":").last!, attributes) } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { if !cancelled(parser) { end?(name.components(separatedBy: ":").last!) } }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if !cancelled(parser) { text?(string) } }
    // XMLParser supplies CDATA callback bytes as UTF-8, independently of source encoding.
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { if !cancelled(parser) { text?(String(decoding: CDATABlock, as: UTF8.self)) } }
    func parse(_ data: Data) throws {
        try Task.checkCancellation()
        let p = XMLParser(data: data); p.delegate = self; p.shouldResolveExternalEntities = false
        let succeeded = p.parse()
        try Task.checkCancellation()
        guard succeeded else { throw ReaderError.invalid("无法解析 EPUB：\(p.parserError?.localizedDescription ?? "XML 格式无效")") }
    }
}
public enum EPUB {
    public static func safeURL(_ relative: String, under root: URL) throws -> URL {
        // ZIP entries and persisted Chapter.path are literal filesystem paths.
        guard !relative.hasPrefix("/"), !relative.contains("://"), !relative.contains("\0") else { throw ReaderError.invalid("EPUB 包含不安全的文件路径") }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let url = base.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(base.path + "/") else { throw ReaderError.invalid("EPUB 文件路径超出书籍目录") }
        return url
    }
    /// Converts an EPUB URL reference to one literal root-relative path. Never decode the result again.
    public static func relativePath(for reference: String, from base: URL, under root: URL) throws -> String {
        guard reference.range(of: "%(?![0-9A-Fa-f]{2})", options: .regularExpression) == nil,
              let components = URLComponents(string: reference), components.scheme == nil, components.host == nil,
              !reference.hasPrefix("/"),
              let decoded = String(reference.prefix { $0 != "?" && $0 != "#" }).removingPercentEncoding,
              !decoded.hasPrefix("/"), !decoded.contains("\0") else { throw ReaderError.invalid("EPUB 章节路径无效") }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolved = base.appendingPathComponent(decoded).resolvingSymlinksInPath().standardizedFileURL
        let prefix = canonicalRoot.path + "/"
        guard resolved.path.hasPrefix(prefix) else { throw ReaderError.invalid("EPUB 章节路径无效") }
        let path = String(resolved.path.dropFirst(prefix.count))
        _ = try safeURL(path, under: canonicalRoot)
        return path
    }
    public static func load(directory: URL) throws -> Book {
        let container = try safeURL("META-INF/container.xml", under: directory)
        var opf = ""
        let c = XML(); c.start = { n,a in if n == "rootfile", opf.isEmpty { opf = a["full-path"] ?? "" } }
        try c.parse(Data(contentsOf: container))
        guard !opf.isEmpty else { throw ReaderError.invalid("EPUB 缺少书籍目录") }
        let package = try safeURL(relativePath(for: opf, from: directory, under: directory), under: directory)
        let base = package.deletingLastPathComponent()
        var title = "", author = "", field = "", manifest: [String:(String,String,String)] = [:], spine: [String] = [], ncxID = "", coverID = ""
        let p = XML()
        p.start = { n,a in
            if n == "title" || n == "creator" { field = n }
            if n == "item", let id = a["id"], let href = a["href"] { manifest[id] = (href,a["media-type"] ?? "",a["properties"] ?? "") }
            if n == "itemref", a["linear"] != "no", let id = a["idref"] { spine.append(id) }
            if n == "spine" { ncxID = a["toc"] ?? "" }
            if n == "meta", a["name"] == "cover" { coverID = a["content"] ?? "" }
        }
        p.text = { if field == "title" { title += $0 }; if field == "creator" { author += $0 } }
        p.end = { if $0 == field { field = "" } }
        try p.parse(Data(contentsOf: package))
        func relative(_ href: String, from baseURL: URL) throws -> String {
            try relativePath(for: href, from: baseURL, under: directory)
        }
        var labels: [String:String] = [:]
        if let item = manifest[ncxID] ?? manifest.values.first(where: { $0.1 == "application/x-dtbncx+xml" }) {
            let tocPath = try relative(item.0, from: base), tocURL = try safeURL(tocPath, under: directory)
            var stack: [(label:String,path:String)] = [], readingLabel = false
            let n = XML()
            n.start = { name,a in
                if name == "navPoint" { stack.append(("","")) }
                if name == "text" { readingLabel = true }
                if name == "content", !stack.isEmpty { stack[stack.count-1].path = a["src"] ?? "" }
            }
            n.text = { if readingLabel, !stack.isEmpty { stack[stack.count-1].label += $0 } }
            n.end = { name in
                if name == "text" { readingLabel = false }
                if name == "navPoint", let entry = stack.popLast(), let key = try? relative(entry.path, from: tocURL.deletingLastPathComponent()) { labels[key] = entry.label.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            try n.parse(Data(contentsOf: tocURL))
        }
        if let nav = manifest.values.first(where: { $0.2.split(separator: " ").contains("nav") }) {
            let navURL = try safeURL(relative(nav.0, from: base), under: directory)
            var href: String?, label = "", tocDepth = 0, depth = 0
            let n = XML()
            n.start = { name,a in
                depth += 1
                if name == "nav", (a["epub:type"] ?? a["type"] ?? "").contains("toc") { tocDepth = depth }
                if name == "a", tocDepth > 0 { href = a["href"]; label = "" }
            }
            n.text = { if href != nil { label += $0 } }
            n.end = { name in
                if name == "a", let h = href, let key = try? relative(h, from: navURL.deletingLastPathComponent()) { if labels[key] == nil { labels[key] = label.trimmingCharacters(in: .whitespacesAndNewlines) }; href = nil }
                if depth == tocDepth { tocDepth = 0 }; depth -= 1
            }
            try n.parse(Data(contentsOf: navURL))
        }
        var chapters: [Chapter] = []
        for id in spine {
            guard let entry = manifest[id], entry.1.contains("html") else { continue }
            let path = try relative(entry.0, from: base)
            chapters.append(Chapter(title: labels[path] ?? "章节 \(chapters.count + 1)", path: path))
        }
        guard !chapters.isEmpty else { throw ReaderError.invalid("这本 EPUB 没有可阅读的文字章节") }
        var cover: String?
        if let item = manifest[coverID] ?? manifest.values.first(where: { $0.2.contains("cover-image") }) { cover = try relative(item.0, from: base) }
        return Book(id: UUID().uuidString, title: title.trimmingCharacters(in: .whitespacesAndNewlines), author: author.trimmingCharacters(in: .whitespacesAndNewlines), chapters: chapters, directory: directory.path, cover: cover)
    }
    public static func importBook(from source: URL, library: URL) throws -> Book {
        try importBookWithOpeningText(from:source,library:library).book
    }
    public static func importBookWithOpeningText(from source: URL, library: URL) throws -> (book:Book,text:String) {
        let fm = FileManager.default, destination = library.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        do {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { throw ReaderError.invalid("找不到文件，请先在 Books 中下载此书") }
            if isDir.boolValue { try fm.copyItem(at: source, to: destination) }
            else {
                let listing = try process("/usr/bin/unzip", ["-Z", "-1", source.path])
                let entries = listing.components(separatedBy: .newlines).filter { !$0.isEmpty }
                guard !entries.isEmpty, entries.count < 50000 else { throw ReaderError.invalid("EPUB 文件目录无效或过大") }
                for entry in entries { _ = try safeURL(entry, under: destination) }
                let detail = try process("/usr/bin/zipinfo", ["-l", source.path])
                guard !detail.components(separatedBy: .newlines).contains(where: { $0.hasPrefix("l") }) else { throw ReaderError.invalid("EPUB 不支持符号链接") }
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                _ = try process("/usr/bin/ditto", ["-x", "-k", source.path, destination.path])
            }
            let encryption = destination.appendingPathComponent("META-INF/encryption.xml")
            if fm.fileExists(atPath: encryption.path) {
                let xml = try String(contentsOf: encryption, encoding: .utf8)
                if xml.contains("EncryptedData"), !xml.contains("http://www.idpf.org/2008/embedding"), !xml.contains("http://ns.adobe.com/pdf/enc#RC") { throw ReaderError.invalid("此 EPUB 受加密保护，无法导入") }
            }
            var book = try load(directory: destination); book.id = destination.lastPathComponent
            return (book,try book.text(at:0))
        } catch { try? fm.removeItem(at: destination); throw error }
    }
    private static func process(_ executable: String, _ arguments: [String]) throws -> String {
        let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments; p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ReaderError.invalid("无法打开 EPUB 压缩文件") }
        return String(decoding: data, as: UTF8.self)
    }
}
public struct ReadingPosition: Codable, Equatable, Sendable {
    public var chapter: Int
    public var character: Int
    public var textVersion: Int
    // Retain an incompatible old offset for recovery; it is never applied to new extraction output.
    public var legacyCharacter: Int?
    public var legacyChapter: Int?
    public init(chapter: Int = 0, character: Int = 0, textVersion: Int = EPUB.textVersion, legacyCharacter: Int? = nil, legacyChapter: Int? = nil) {
        self.chapter = chapter; self.character = character; self.textVersion = textVersion; self.legacyCharacter = legacyCharacter; self.legacyChapter = legacyChapter
    }
    enum CodingKeys: String, CodingKey { case chapter, character, textVersion, legacyCharacter, legacyChapter }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        chapter = try values.decode(Int.self, forKey: .chapter)
        character = try values.decode(Int.self, forKey: .character)
        textVersion = try values.decodeIfPresent(Int.self, forKey: .textVersion) ?? 1
        legacyCharacter = try values.decodeIfPresent(Int.self, forKey: .legacyCharacter)
        legacyChapter = try values.decodeIfPresent(Int.self, forKey: .legacyChapter)
    }
    public var requiresTextMigration: Bool { textVersion != EPUB.textVersion }

}
public enum ReadingMode: String, Codable, Sendable { case paged, scrolling }

public struct ReaderPreferences: Codable, Equatable, Sendable {
    public var readingMode: ReadingMode = .paged
    public var fontSize: Double = 20
    public var stealthFontSize: Double = 11
    public var brightness: Double = 1
    public var textOpacity: Double = 1
    public var adaptiveText: Bool = true
    public var appearanceVersion: Int = 2
    public var opacity: Double = 0.92
    public var floating: Bool = true
    public var theme: String = "system"
    public var fontName: String = "serif"
    public var stealthFontName: String = "system"
    public var lineHeight: Double = 1.35
    public var stealthLineHeight: Double = 1.15
    public var paragraphSpacing: Double = 4
    public var stealthParagraphSpacing: Double = 0
    public var margin: Double = 48
    public init() {}
    enum CodingKeys: String, CodingKey { case appearanceVersion, textOpacity, adaptiveText, readingMode, fontSize, stealthFontSize, brightness, opacity, floating, theme, fontName, stealthFontName, lineHeight, stealthLineHeight, paragraphSpacing, stealthParagraphSpacing, margin }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        readingMode = try c.decodeIfPresent(ReadingMode.self,forKey:.readingMode) ?? .paged
        fontSize = try c.decodeIfPresent(Double.self,forKey:.fontSize) ?? 20
        stealthFontSize = try c.decodeIfPresent(Double.self,forKey:.stealthFontSize) ?? 11
        appearanceVersion = 2
        let oldVersion = try c.decodeIfPresent(Int.self,forKey:.appearanceVersion) ?? 1
        brightness = oldVersion < 2 ? 1 : (try c.decodeIfPresent(Double.self,forKey:.brightness) ?? 1)
        textOpacity = try c.decodeIfPresent(Double.self,forKey:.textOpacity) ?? 1
        adaptiveText = try c.decodeIfPresent(Bool.self,forKey:.adaptiveText) ?? true
        opacity = try c.decodeIfPresent(Double.self,forKey:.opacity) ?? 0.92
        floating = try c.decodeIfPresent(Bool.self,forKey:.floating) ?? true
        theme = try c.decodeIfPresent(String.self,forKey:.theme) ?? "system"
        fontName = try c.decodeIfPresent(String.self,forKey:.fontName) ?? "serif"
        stealthFontName = try c.decodeIfPresent(String.self,forKey:.stealthFontName) ?? "system"
        lineHeight = try c.decodeIfPresent(Double.self,forKey:.lineHeight) ?? 1.35
        stealthLineHeight = try c.decodeIfPresent(Double.self,forKey:.stealthLineHeight) ?? 1.15
        paragraphSpacing = try c.decodeIfPresent(Double.self,forKey:.paragraphSpacing) ?? 4
        stealthParagraphSpacing = try c.decodeIfPresent(Double.self,forKey:.stealthParagraphSpacing) ?? 0
        margin = try c.decodeIfPresent(Double.self,forKey:.margin) ?? 48
    }
}
extension ReaderPreferences {
    public mutating func adjustBrightness(by delta:Double) { brightness = min(1,max(0,(brightness+delta)*100).rounded()/100) }
    public mutating func adjustTransparency(by delta:Double) { opacity = min(1,max(0,((opacity-delta)*100).rounded()/100)) }
}
public struct LibraryState: Codable, Equatable, Sendable {
    public var books: [Book] = []
    public var positions: [String:ReadingPosition] = [:]
    public var selectedBook: String?
    public var preferences = ReaderPreferences()
    public init() {}
    public func save(to url: URL) throws { try JSONEncoder().encode(self).write(to: url, options: .atomic) }
    public static func load(from url: URL) throws -> LibraryState { try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
}
