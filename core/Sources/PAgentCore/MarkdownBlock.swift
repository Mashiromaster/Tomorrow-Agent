import Foundation

/// A minimal block-level Markdown splitter.
///
/// ## Why this exists rather than `AttributedString(markdown:)` alone
///
/// `AttributedString` handles *inline* syntax — `**bold**`, `*italic*`,
/// `` `code` `` — and does it well. What it does not do is block structure:
/// measured against the real parser, `- item` and `# heading` come back as
/// literal text, dash and hash included. The model's prose uses lists and
/// headings constantly, so rendering with `AttributedString` alone shows the
/// user raw syntax.
///
/// ## Why it is this small
///
/// A full CommonMark implementation would be a dependency, and §2.3 keeps the
/// device's attack surface minimal — this text comes from a remote model, and
/// §9.4 treats model output as untrusted. The subset here is what the agent
/// actually emits: paragraphs, bullet and numbered lists, headings, fenced
/// code, and block quotes. Anything unrecognised stays a paragraph, which
/// degrades to "renders as written" rather than to an error.
///
/// Inline syntax inside each block is still left to `AttributedString`, which
/// is where it belongs.
public enum MarkdownBlock: Sendable, Hashable, Identifiable {
    case paragraph(String)
    /// `level` is clamped to 1...3; deeper headings are rare in chat prose and
    /// would render smaller than body text.
    case heading(level: Int, text: String)
    case bulleted([String])
    case numbered([(number: Int, text: String)])
    /// Fenced code. `language` is captured but unused for now — no syntax
    /// highlighting, which would mean another parser.
    case code(language: String?, text: String)
    case quote(String)

    public var id: Int { hashValue }

    public static func == (lhs: MarkdownBlock, rhs: MarkdownBlock) -> Bool {
        switch (lhs, rhs) {
        case (.paragraph(let a), .paragraph(let b)): a == b
        case (.heading(let la, let a), .heading(let lb, let b)): la == lb && a == b
        case (.bulleted(let a), .bulleted(let b)): a == b
        case (.numbered(let a), .numbered(let b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.number == $1.number && $0.text == $1.text }
        case (.code(let la, let a), .code(let lb, let b)): la == lb && a == b
        case (.quote(let a), .quote(let b)): a == b
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .paragraph(let text): hasher.combine(0); hasher.combine(text)
        case .heading(let level, let text): hasher.combine(1); hasher.combine(level); hasher.combine(text)
        case .bulleted(let items): hasher.combine(2); hasher.combine(items)
        case .numbered(let items):
            hasher.combine(3)
            for item in items { hasher.combine(item.number); hasher.combine(item.text) }
        case .code(let language, let text): hasher.combine(4); hasher.combine(language); hasher.combine(text)
        case .quote(let text): hasher.combine(5); hasher.combine(text)
        }
    }
}

extension MarkdownBlock {
    /// Splits text into blocks.
    ///
    /// Streaming-safe: called on every delta while a response arrives, so it
    /// has to tolerate text that stops mid-block. An unterminated code fence
    /// yields a code block with what has arrived so far rather than falling
    /// back to a paragraph — otherwise the content would visibly flip from
    /// prose to code the moment the closing fence lands.
    public static func blocks(from markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbers: [(number: Int, text: String)] = []
        var quote: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }
        func flushBullets() {
            guard !bullets.isEmpty else { return }
            blocks.append(.bulleted(bullets))
            bullets.removeAll()
        }
        func flushNumbers() {
            guard !numbers.isEmpty else { return }
            blocks.append(.numbered(numbers))
            numbers.removeAll()
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(quote.joined(separator: "\n")))
            quote.removeAll()
        }
        func flushAll() {
            flushParagraph()
            flushBullets()
            flushNumbers()
            flushQuote()
        }

        var lines = markdown.components(separatedBy: "\n")[...]

        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code. Consumes until the closing fence or the end of the
            // input, whichever comes first.
            if trimmed.hasPrefix("```") {
                flushAll()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                while let next = lines.first {
                    lines = lines.dropFirst()
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    body.append(next)
                }
                blocks.append(
                    .code(
                        language: language.isEmpty ? nil : language,
                        text: body.joined(separator: "\n")
                    )
                )
                continue
            }

            if trimmed.isEmpty {
                // A blank line ends a paragraph or a quote, but **not** a
                // list. CommonMark calls the spaced-out form a "loose list",
                // and it is what the model writes by default — flushing here
                // turned one list of three into three lists of one, which
                // renders as three separate blocks with wrong spacing.
                //
                // The list is closed by the next non-item line instead, or by
                // the end of the input.
                flushParagraph()
                flushQuote()
                continue
            }

            if let heading = Self.heading(in: trimmed) {
                flushAll()
                blocks.append(heading)
                continue
            }

            if let item = Self.bulletItem(in: trimmed) {
                flushParagraph()
                flushNumbers()
                flushQuote()
                bullets.append(item)
                continue
            }

            if let item = Self.numberedItem(in: trimmed) {
                flushParagraph()
                flushBullets()
                flushQuote()
                numbers.append(item)
                continue
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                flushBullets()
                flushNumbers()
                quote.append(String(trimmed.dropFirst(trimmed == ">" ? 1 : 2)))
                continue
            }

            flushBullets()
            flushNumbers()
            flushQuote()
            paragraph.append(line)
        }

        flushAll()
        return blocks
    }

    private static func heading(in line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 6 else { return nil }
        let rest = line.dropFirst(hashes.count)
        // `#tag` is not a heading — ATX requires a space after the hashes.
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: min(hashes.count, 3), text: text)
    }

    private static func bulletItem(in line: String) -> String? {
        // Requiring the trailing space is what keeps `**bold**` out: it does
        // not start with `"* "`. (An earlier version carried an extra guard
        // for that case; mutation testing showed deleting it changed nothing,
        // because this `where` clause had already excluded it.)
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func numberedItem(in line: String) -> (number: Int, text: String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, let number = Int(digits) else { return nil }
        var rest = line.dropFirst(digits.count)
        guard rest.first == "." || rest.first == ")" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }
        return (number, rest.trimmingCharacters(in: .whitespaces))
    }
}
