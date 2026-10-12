import Foundation

public struct Chapter: Codable, Equatable {
    public let title: String
    public let path: String
}
public struct Book: Codable, Identifiable {
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
private final class XML: NSObject, XMLParserDelegate {
    var start: ((String, [String:String]) -> Void)?
    var end: ((String) -> Void)?
    var text: ((String) -> Void)?
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) { start?(name.components(separatedBy: ":").last!, attributes) }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { end?(name.components(separatedBy: ":").last!) }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text?(string) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text?(String(decoding: CDATABlock, as: UTF8.self)) }
    func parse(_ data: Data) throws {
        let p = XMLParser(data: data); p.delegate = self; p.shouldResolveExternalEntities = false
        guard p.parse() else { throw ReaderError.invalid("无法解析 EPUB：\(p.parserError?.localizedDescription ?? "XML 格式无效")") }
    }
}
public enum EPUB {
    public static func safeURL(_ relative: String, under root: URL) throws -> URL {
        let decoded = relative.removingPercentEncoding ?? relative
        guard !decoded.hasPrefix("/"), !decoded.contains("://"), !decoded.contains("\0") else { throw ReaderError.invalid("EPUB 包含不安全的文件路径") }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let url = base.appendingPathComponent(decoded).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(base.path + "/") else { throw ReaderError.invalid("EPUB 文件路径超出书籍目录") }
        return url
    }
    public static func load(directory: URL) throws -> Book {
        let container = try safeURL("META-INF/container.xml", under: directory)
        var opf = ""
        let c = XML(); c.start = { n,a in if n == "rootfile", opf.isEmpty { opf = a["full-path"] ?? "" } }
        try c.parse(Data(contentsOf: container))
        guard !opf.isEmpty else { throw ReaderError.invalid("EPUB 缺少书籍目录") }
        let package = try safeURL(opf, under: directory)
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
            let file = href.components(separatedBy: "#")[0]
            let resolved = baseURL.appendingPathComponent(file.removingPercentEncoding ?? file).standardizedFileURL
            let prefix = directory.standardizedFileURL.path + "/"
            guard resolved.path.hasPrefix(prefix) else { throw ReaderError.invalid("EPUB 章节路径无效") }
            let path = String(resolved.path.dropFirst(prefix.count))
            _ = try safeURL(path, under: directory)
            return path
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
    public static func plainText(_ data: Data) throws -> String {
        var result = "", depth = 0, bodyDepth = 0, ignoredDepth = 0
        let blocks: Set<String> = ["p","div","h1","h2","h3","h4","li","blockquote","section","br","tr"]
        let x = XML()
        x.start = { n,a in
            depth += 1
            if n == "body" { bodyDepth = depth }
            if ignoredDepth == 0, n == "script" || n == "style" || a["hidden"] != nil || (a["style"] ?? "").replacingOccurrences(of: " ", with: "").contains("display:none") { ignoredDepth = depth }
            if bodyDepth > 0, ignoredDepth == 0, blocks.contains(n), !result.hasSuffix("\n") { result += "\n" }
        }
        x.text = { if bodyDepth > 0, ignoredDepth == 0 { result += $0 } }
        x.end = { n in
            if bodyDepth > 0, ignoredDepth == 0, blocks.contains(n), !result.hasSuffix("\n") { result += "\n" }
            if depth == ignoredDepth { ignoredDepth = 0 }
            if depth == bodyDepth { bodyDepth = 0 }
            depth -= 1
        }
        // Common XHTML named entities are normalized without resolving remote DTDs.
        var normalized = String(decoding: data, as: UTF8.self)
        for (key,value) in ["&nbsp;":"&#160;", "&mdash;":"&#8212;", "&ndash;":"&#8211;", "&hellip;":"&#8230;", "&ldquo;":"&#8220;", "&rdquo;":"&#8221;", "&lsquo;":"&#8216;", "&rsquo;":"&#8217;"] { normalized = normalized.replacingOccurrences(of: key, with: value) }
        do { try x.parse(Data(normalized.utf8)) }
        catch {
            // Some EPUBs contain HTML with omitted closing tags. Repair structure locally.
            let repaired = try XMLDocument(data: Data(normalized.utf8), options: [.documentTidyXML, .nodeLoadExternalEntitiesNever])
            result = ""; depth = 0; bodyDepth = 0; ignoredDepth = 0
            try x.parse(repaired.xmlData)
        }
        return result.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    public static func importBook(from source: URL, library: URL) throws -> Book {
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
            return book
        } catch { try? fm.removeItem(at: destination); throw error }
    }
    private static func process(_ executable: String, _ arguments: [String]) throws -> String {
        let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments; p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ReaderError.invalid("无法打开 EPUB 压缩文件") }
        return String(decoding: data, as: UTF8.self)
    }
}
public struct ReadingPosition: Codable, Equatable {
    public var chapter: Int
    public var character: Int
    public init(chapter: Int = 0, character: Int = 0) { self.chapter = chapter; self.character = character }
}
public struct ReaderPreferences: Codable {
    public var fontSize: Double = 20
    public var stealthFontSize: Double = 11
    public var brightness: Double = 0.94
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
    enum CodingKeys: String, CodingKey { case fontSize, stealthFontSize, brightness, opacity, floating, theme, fontName, stealthFontName, lineHeight, stealthLineHeight, paragraphSpacing, stealthParagraphSpacing, margin }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try c.decodeIfPresent(Double.self,forKey:.fontSize) ?? 20
        stealthFontSize = try c.decodeIfPresent(Double.self,forKey:.stealthFontSize) ?? 11
        brightness = try c.decodeIfPresent(Double.self,forKey:.brightness) ?? 0.94
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
public struct LibraryState: Codable {
    public var books: [Book] = []
    public var positions: [String:ReadingPosition] = [:]
    public var selectedBook: String?
    public var preferences = ReaderPreferences()
    public init() {}
    public func save(to url: URL) throws { try JSONEncoder().encode(self).write(to: url, options: .atomic) }
    public static func load(from url: URL) throws -> LibraryState { try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
}
