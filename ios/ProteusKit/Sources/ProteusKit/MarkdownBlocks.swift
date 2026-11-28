import Foundation

/// One list entry. `marker` is a bullet or "1." etc; `indent` is the nesting depth.
public struct MarkdownListItem: Equatable, Sendable {
    public var indent: Int
    public var marker: String
    public var text: String

    public init(indent: Int, marker: String, text: String) {
        self.indent = indent
        self.marker = marker
        self.text = text
    }
}

/// A block-level piece of an assistant reply. Inline markup (bold, italic,
/// code, links) stays in the strings and is rendered per block by
/// `MarkdownBlocks.inline`.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MarkdownListItem])
    case code(language: String?, text: String)
    case table(header: [String], rows: [[String]])
    case quote(String)
    case rule
}

public enum MarkdownBlocks {
    /// Splits markdown text into blocks. Never throws; unknown syntax becomes
    /// a paragraph. Tolerant of a still-streaming (unterminated) code fence.
    public static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var list: [MarkdownListItem] = []
        var quote: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        func flushList() {
            if !list.isEmpty {
                blocks.append(.list(list))
                list = []
            }
        }
        func flushQuote() {
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: "\n")))
                quote = []
            }
        }
        func flushAll() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                let fence = String(trimmed.prefix(3))
                let tag = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count,
                      !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[i])
                    i += 1
                }
                i += 1 // closing fence (or end of text)
                blocks.append(.code(language: tag.isEmpty ? nil : tag, text: body.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                i += 1
                continue
            }

            if let parsed = heading(trimmed) {
                flushAll()
                blocks.append(.heading(level: parsed.0, text: parsed.1))
                i += 1
                continue
            }

            if isRule(trimmed) {
                flushAll()
                blocks.append(.rule)
                i += 1
                continue
            }

            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushAll()
                let header = splitRow(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    if row.isEmpty || !row.contains("|") { break }
                    rows.append(splitRow(row))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                var content = String(trimmed.dropFirst())
                if content.hasPrefix(" ") { content.removeFirst() }
                quote.append(content)
                i += 1
                continue
            }

            if let item = listItem(line) {
                flushParagraph()
                flushQuote()
                list.append(item)
                i += 1
                continue
            }

            // Indented continuation of the last list item.
            if !list.isEmpty, line.hasPrefix(" ") || line.hasPrefix("\t") {
                list[list.count - 1].text += " " + trimmed
                i += 1
                continue
            }

            flushList()
            flushQuote()
            paragraph.append(trimmed)
            i += 1
        }
        flushAll()
        return blocks
    }

    /// Inline markup (bold, italic, code, links) for one block. Newlines are
    /// kept. Falls back to the plain text if the markup does not parse.
    public static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    // MARK: Helpers

    private static func heading(_ trimmed: String) -> (Int, String)? {
        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var content = rest.trimmingCharacters(in: .whitespaces)
        // Closing hashes: "## Title ##".
        while content.hasSuffix("#") { content.removeLast() }
        content = content.trimmingCharacters(in: .whitespaces)
        return (level, content)
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        return trimmed.allSatisfy { "|-: \t".contains($0) }
    }

    private static func splitRow(_ row: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in row {
            if escaped {
                if ch != "|" { current.append("\\") }
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        cells.append(current)
        var trimmed = cells.map { $0.trimmingCharacters(in: .whitespaces) }
        if row.hasPrefix("|"), !trimmed.isEmpty { trimmed.removeFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|"), !trimmed.isEmpty { trimmed.removeLast() }
        return trimmed
    }

    private static func listItem(_ line: String) -> MarkdownListItem? {
        var leading = 0
        for ch in line {
            if ch == " " { leading += 1 } else if ch == "\t" { leading += 4 } else { break }
        }
        let body = line.trimmingCharacters(in: .whitespaces)
        for bullet in ["- ", "* ", "+ "] where body.hasPrefix(bullet) {
            let text = String(body.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return MarkdownListItem(indent: min(leading / 2, 4), marker: "\u{2022}", text: text)
        }
        var digits = ""
        var rest = Substring(body)
        while let ch = rest.first, ch.isNumber, digits.count < 9 {
            digits.append(ch)
            rest = rest.dropFirst()
        }
        if !digits.isEmpty, let sep = rest.first, sep == "." || sep == ")",
           rest.dropFirst().first == " " {
            let text = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return MarkdownListItem(indent: min(leading / 2, 4), marker: digits + ".", text: text)
        }
        return nil
    }
}
