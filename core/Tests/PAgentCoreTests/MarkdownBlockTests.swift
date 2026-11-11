import Foundation
import Testing

@testable import PAgentCore

/// The parser only has to handle what the agent actually emits, so these
/// tests are built from real model output rather than from the CommonMark
/// spec — passing a spec suite is not the goal and would imply a completeness
/// this deliberately does not have.
@Suite("Markdown blocks")
struct MarkdownBlockTests {
    @Test("plain prose is one paragraph")
    func paragraph() {
        #expect(MarkdownBlock.blocks(from: "一句话。") == [.paragraph("一句话。")])
    }

    @Test("a blank line separates paragraphs")
    func paragraphSplit() {
        let blocks = MarkdownBlock.blocks(from: "第一段。\n\n第二段。")
        #expect(blocks == [.paragraph("第一段。"), .paragraph("第二段。")])
    }

    @Test("consecutive lines stay in one paragraph")
    func softWrap() {
        // A hard-wrapped paragraph is still one paragraph; splitting on every
        // newline would double the spacing of ordinary prose.
        #expect(MarkdownBlock.blocks(from: "第一行\n第二行") == [.paragraph("第一行\n第二行")])
    }

    @Test("bullets collapse into one list")
    func bullets() {
        let blocks = MarkdownBlock.blocks(from: "- 一\n- 二\n- 三")
        #expect(blocks == [.bulleted(["一", "二", "三"])])
    }

    @Test("all three bullet markers work")
    func bulletMarkers() {
        #expect(MarkdownBlock.blocks(from: "* 一") == [.bulleted(["一"])])
        #expect(MarkdownBlock.blocks(from: "+ 一") == [.bulleted(["一"])])
    }

    @Test("emphasis at the start of a line is not a bullet")
    func boldIsNotABullet() {
        // The bullet marker is `"* "` *with* the space, so none of these are
        // list items. Worth pinning: dropping the space from the marker is an
        // easy "simplification" that would turn every bolded lead-in into a
        // bullet.
        #expect(MarkdownBlock.blocks(from: "**注意**：别这样。") == [.paragraph("**注意**：别这样。")])
        #expect(MarkdownBlock.blocks(from: "*斜体* 开头。") == [.paragraph("*斜体* 开头。")])
        #expect(MarkdownBlock.blocks(from: "** 注意 **：别这样。") == [.paragraph("** 注意 **：别这样。")])
    }

    @Test("numbered items keep their own numbers")
    func numbered() {
        let blocks = MarkdownBlock.blocks(from: "1. 一\n2. 二")
        guard case .numbered(let items) = blocks.first, blocks.count == 1 else {
            Issue.record("expected one numbered list, got \(blocks)")
            return
        }
        // The model's numbering is preserved rather than regenerated: it
        // sometimes continues a list across a paragraph, and renumbering from
        // 1 would contradict the prose referring to "step 3".
        #expect(items.map(\.number) == [1, 2])
        #expect(items.map(\.text) == ["一", "二"])
    }

    @Test("a `)` delimiter is also a numbered item")
    func numberedParen() {
        guard case .numbered(let items)? = MarkdownBlock.blocks(from: "1) 一").first else {
            Issue.record("expected a numbered list")
            return
        }
        #expect(items.first?.text == "一")
    }

    @Test("a date-like line is not a numbered list")
    func dateIsNotAList() {
        // "2026. 11" would parse as item 2026 under a looser rule.
        #expect(MarkdownBlock.blocks(from: "11.5 公里") == [.paragraph("11.5 公里")])
    }

    @Test("headings are levelled and clamped")
    func headings() {
        #expect(MarkdownBlock.blocks(from: "# 大") == [.heading(level: 1, text: "大")])
        #expect(MarkdownBlock.blocks(from: "## 中") == [.heading(level: 2, text: "中")])
        // Deeper than 3 would render smaller than body text, which reads as a
        // mistake rather than as structure.
        #expect(MarkdownBlock.blocks(from: "##### 小") == [.heading(level: 3, text: "小")])
    }

    @Test("a hash without a space is not a heading")
    func hashtagIsNotAHeading() {
        #expect(MarkdownBlock.blocks(from: "#徒步 很好") == [.paragraph("#徒步 很好")])
    }

    @Test("fenced code keeps its text verbatim")
    func code() {
        let blocks = MarkdownBlock.blocks(from: "```swift\nlet x = 1\n\nlet y = 2\n```")
        // The blank line inside must survive: splitting code on blank lines
        // would mangle every multi-paragraph snippet.
        #expect(blocks == [.code(language: "swift", text: "let x = 1\n\nlet y = 2")])
    }

    @Test("an unterminated fence still renders as code")
    func streamingCode() {
        // Mid-stream: the closing fence has not arrived yet. Treating this as
        // a paragraph would make the block visibly flip from prose to code
        // when it does.
        let blocks = MarkdownBlock.blocks(from: "```\nlet x = 1")
        #expect(blocks == [.code(language: nil, text: "let x = 1")])
    }

    @Test("markdown inside a fence is not parsed")
    func codeIsOpaque() {
        let blocks = MarkdownBlock.blocks(from: "```\n# not a heading\n- not a bullet\n```")
        #expect(blocks == [.code(language: nil, text: "# not a heading\n- not a bullet")])
    }

    @Test("quotes collapse into one block")
    func quotes() {
        #expect(MarkdownBlock.blocks(from: "> 一\n> 二") == [.quote("一\n二")])
    }

    @Test("a realistic answer parses into the blocks it looks like")
    func realAnswer() {
        // Taken from an actual response — the shape this parser exists for.
        let text = """
            缺一个关键信息：**这是哪一天**。

            另外先说明两点限制：
            - 你的作息规律取不到
            - 我不能写入日历，只能出提案

            所以请告诉我：
            1. 周六的具体日期
            2. 上午大致想干什么
            """
        let blocks = MarkdownBlock.blocks(from: text)
        #expect(blocks.count == 5)
        #expect(blocks[0] == .paragraph("缺一个关键信息：**这是哪一天**。"))
        #expect(blocks[1] == .paragraph("另外先说明两点限制："))
        if case .bulleted(let items) = blocks[2] {
            #expect(items.count == 2)
        } else {
            Issue.record("expected bullets at index 2, got \(blocks[2])")
        }
        #expect(blocks[3] == .paragraph("所以请告诉我："))
        if case .numbered(let items) = blocks[4] {
            #expect(items.map(\.number) == [1, 2])
        } else {
            Issue.record("expected a numbered list at index 4, got \(blocks[4])")
        }
    }

    @Test("empty input yields no blocks")
    func empty() {
        #expect(MarkdownBlock.blocks(from: "").isEmpty)
        #expect(MarkdownBlock.blocks(from: "\n\n  \n").isEmpty)
    }
}

// MARK: - Loose lists

/// The model separates list items with blank lines (CommonMark's "loose
/// list"). An earlier version flushed the list on every blank line, turning
/// one list of three into three lists of one — found by reading a real stored
/// answer back out of the database, not by a test.
@Suite("Loose lists")
struct LooseListTests {
    @Test("blank lines between numbered items keep one list")
    func looseNumbered() {
        let text = "1. 一\n\n2. 二\n\n3. 三"
        guard case .numbered(let items)? = MarkdownBlock.blocks(from: text).first,
            MarkdownBlock.blocks(from: text).count == 1
        else {
            Issue.record("expected one list, got \(MarkdownBlock.blocks(from: text))")
            return
        }
        #expect(items.map(\.number) == [1, 2, 3])
    }

    @Test("blank lines between bullets keep one list")
    func looseBulleted() {
        #expect(MarkdownBlock.blocks(from: "- 一\n\n- 二") == [.bulleted(["一", "二"])])
    }

    @Test("a paragraph after a blank line still ends the list")
    func paragraphClosesList() {
        // The blank line alone must not close it, but the prose after one
        // must — otherwise everything below a list joins it.
        let blocks = MarkdownBlock.blocks(from: "- 一\n\n后续说明。")
        #expect(blocks == [.bulleted(["一"]), .paragraph("后续说明。")])
    }

    @Test("a heading after a blank line closes the list")
    func headingClosesList() {
        let blocks = MarkdownBlock.blocks(from: "- 一\n\n## 标题")
        #expect(blocks == [.bulleted(["一"]), .heading(level: 2, text: "标题")])
    }

    @Test("the real answer that exposed this parses as one list")
    func realLooseAnswer() {
        // Recovered verbatim from the store after a round trip.
        let text = """
            **三件我做不到的事：**

            1. **不能写入你的日历或提醒事项。** 我没有任何写入工具。

            2. **不能联网查实时信息。** 没有浏览器。

            3. **不能记住上一次对话。** 每次都是新的。
            """
        let blocks = MarkdownBlock.blocks(from: text)
        #expect(blocks.count == 2)
        #expect(blocks.first == .paragraph("**三件我做不到的事：**"))
        if case .numbered(let items) = blocks.last {
            #expect(items.count == 3)
            #expect(items.map(\.number) == [1, 2, 3])
        } else {
            Issue.record("expected one numbered list, got \(String(describing: blocks.last))")
        }
    }
}
