import Foundation

extension EPUB {
    public static let textVersion = 2

    public static func plainText(_ data: Data) throws -> String {
        let source = try normalizedXML(data)
        let output = PlainTextOutput()
        var depth = 0, bodyDepth = 0, ignoredDepth = 0, preDepth = 0
        let blocks: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "section", "article", "header", "footer", "ul", "ol", "table", "tr", "pre"]
        let parser = XML()
        parser.start = { name, attributes in
            depth += 1
            if name == "body" { bodyDepth = depth }
            if ignoredDepth == 0, name == "script" || name == "style" || attributes["hidden"] != nil || (attributes["style"] ?? "").replacingOccurrences(of: " ", with: "").contains("display:none") { ignoredDepth = depth }
            guard bodyDepth > 0, ignoredDepth == 0 else { return }
            if name == "br" { output.boundary(1) }
            else if blocks.contains(name) { output.boundary(2) }
            if name == "pre", preDepth == 0 { preDepth = depth }
        }
        parser.text = { text in
            if bodyDepth > 0, ignoredDepth == 0 { output.append(text, preformatted: preDepth > 0) }
        }
        parser.end = { name in
            if bodyDepth > 0, ignoredDepth == 0 {
                if blocks.contains(name) { output.boundary(2) }
                else if name == "td" || name == "th" { output.cellBoundary() }
            }
            if depth == preDepth { preDepth = 0 }
            if depth == ignoredDepth { ignoredDepth = 0 }
            if depth == bodyDepth { bodyDepth = 0 }
            depth -= 1
        }
        try parser.parse(Data(source.utf8))
        return output.text
    }

    /// EPUB XML resources support UTF-8/UTF-16. Decode strictly once and keep the
    /// declaration consistent with the UTF-8 bytes supplied to XMLParser.
    static func normalizedXML(_ data: Data) throws -> String {
        try Task.checkCancellation()
        let bytes = Array(data.prefix(4))
        var start = 0
        let encoding: String.Encoding
        let kind: String
        if bytes.starts(with: [0, 0, 0xFE, 0xFF]) || bytes.starts(with: [0xFF, 0xFE, 0, 0]) {
            throw ReaderError.invalid("EPUB 文字编码不受支持")
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian; kind = "UTF-16LE"; start = 2
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian; kind = "UTF-16BE"; start = 2
        } else if bytes.count >= 4, bytes[0] == 0x3C, bytes[1] == 0, bytes[3] == 0 {
            encoding = .utf16LittleEndian; kind = "UTF-16LE"
        } else if bytes.count >= 4, bytes[0] == 0, bytes[1] == 0x3C, bytes[2] == 0 {
            encoding = .utf16BigEndian; kind = "UTF-16BE"
        } else {
            encoding = .utf8; kind = "UTF-8"
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { start = 3 }
        }
        let payload = data.dropFirst(start)
        if kind != "UTF-8" { try validateUTF16(Array(payload), littleEndian: kind == "UTF-16LE") }
        guard var source = String(data: payload, encoding: encoding) else { throw ReaderError.invalid("EPUB 文字编码无效") }
        let declaration = try NSRegularExpression(pattern: #"^<\?xml\s[^?]*\bencoding\s*=\s*(['"])([^'"]+)\1"#, options: .caseInsensitive)
        if let match = declaration.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), let range = Range(match.range(at: 2), in: source) {
            let declared = source[range].uppercased()
            guard declared == kind || (declared == "UTF-16" && kind.hasPrefix("UTF-16")) else { throw ReaderError.invalid("EPUB 文字编码与声明不一致") }
            source.replaceSubrange(range, with: "UTF-8")
        }
        return try normalizeEntities(source)
    }

    private static func validateUTF16(_ bytes: [UInt8], littleEndian: Bool) throws {
        guard bytes.count.isMultiple(of: 2) else { throw ReaderError.invalid("EPUB UTF-16 文字编码无效") }
        func unit(_ i: Int) -> UInt16 { littleEndian ? UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 : UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) }
        var index = 0
        while index < bytes.count {
            let value = unit(index); index += 2
            if (0xD800...0xDBFF).contains(value) {
                guard index < bytes.count, (0xDC00...0xDFFF).contains(unit(index)) else { throw ReaderError.invalid("EPUB UTF-16 文字编码无效") }
                index += 2
            } else if (0xDC00...0xDFFF).contains(value) { throw ReaderError.invalid("EPUB UTF-16 文字编码无效") }
        }
    }

    private static func normalizeEntities(_ source: String) throws -> String {
        let entities = ["&nbsp;": "&#160;", "&mdash;": "&#8212;", "&ndash;": "&#8211;", "&hellip;": "&#8230;", "&ldquo;": "&#8220;", "&rdquo;": "&#8221;", "&lsquo;": "&#8216;", "&rsquo;": "&#8217;"]
        var result = "", index = source.startIndex, checked = 0
        result.reserveCapacity(source.utf8.count)
        while index < source.endIndex {
            checked += 1
            if checked.isMultiple(of: 4096) { try Task.checkCancellation() }
            let tail = source[index...]
            let terminator: String? = tail.hasPrefix("<![CDATA[") ? "]]>" : (tail.hasPrefix("<!--") ? "-->" : (tail.hasPrefix("<?") ? "?>" : nil))
            if let terminator {
                let end = tail.range(of: terminator)?.upperBound ?? source.endIndex
                result += source[index..<end]; index = end; continue
            }
            if tail.hasPrefix("<!DOCTYPE") {
                var end = index, quote: Character?, brackets = 0
                while end < source.endIndex {
                    let character = source[end]; end = source.index(after: end)
                    if let current = quote { if character == current { quote = nil }; continue }
                    if character == "\"" || character == "'" { quote = character }
                    else if character == "[" { brackets += 1 }
                    else if character == "]" { brackets -= 1 }
                    else if character == ">", brackets == 0 { break }
                }
                result += source[index..<end]; index = end; continue
            }
            if source[index] == "&", let entry = entities.first(where: { tail.hasPrefix($0.key) }) {
                result += entry.value; index = source.index(index, offsetBy: entry.key.count)
            } else { result.append(source[index]); index = source.index(after: index) }
        }
        return result
    }
}

private final class PlainTextOutput {
    var text = ""
    private var lineBreaks = 0, space = false, cell = false
    func boundary(_ count: Int) { lineBreaks = max(lineBreaks, count); space = false; cell = false }
    func cellBoundary() { cell = true; space = false }
    private func flush() {
        if !text.isEmpty {
            if lineBreaks > 0 {
                let existing = text.hasSuffix("\n\n") ? 2 : (text.hasSuffix("\n") ? 1 : 0)
                if lineBreaks > existing { text += String(repeating: "\n", count: lineBreaks - existing) }
            } else if cell { text += "\t" }
            else if space, !text.hasSuffix("\n"), !text.hasSuffix(" ") { text += " " }
        }
        lineBreaks = 0; space = false; cell = false
    }
    func append(_ value: String, preformatted: Bool) {
        if preformatted { flush(); text += value; return }
        for character in value {
            if character == " " || character == "\t" || character == "\r" || character == "\n" { space = true }
            else { flush(); text.append(character) }
        }
    }
}
