import XCTest
@testable import ProteusKit

final class MarkdownBlocksTests: XCTestCase {
    func testParagraphsAreSeparateBlocks() {
        let blocks = MarkdownBlocks.parse("First paragraph.\n\nSecond paragraph.")
        XCTAssertEqual(blocks, [.paragraph("First paragraph."), .paragraph("Second paragraph.")])
    }

    func testHeadingThenParagraph() {
        let blocks = MarkdownBlocks.parse("## Hypotheses\nCache misses: likely.")
        XCTAssertEqual(blocks, [.heading(level: 2, text: "Hypotheses"), .paragraph("Cache misses: likely.")])
    }

    func testBulletAndOrderedLists() {
        let blocks = MarkdownBlocks.parse("- one\n- two\n  - nested\n\n1. a\n2. b")
        XCTAssertEqual(blocks, [
            .list([
                MarkdownListItem(indent: 0, marker: "\u{2022}", text: "one"),
                MarkdownListItem(indent: 0, marker: "\u{2022}", text: "two"),
                MarkdownListItem(indent: 1, marker: "\u{2022}", text: "nested"),
            ]),
            .list([
                MarkdownListItem(indent: 0, marker: "1.", text: "a"),
                MarkdownListItem(indent: 0, marker: "2.", text: "b"),
            ]),
        ])
    }

    func testCodeFenceKeepsContentAndToleratesMissingClose() {
        XCTAssertEqual(
            MarkdownBlocks.parse("```swift\nlet a = 1\n\nlet b = 2\n```"),
            [.code(language: "swift", text: "let a = 1\n\nlet b = 2")]
        )
        XCTAssertEqual(
            MarkdownBlocks.parse("text\n```\nopen"),
            [.paragraph("text"), .code(language: nil, text: "open")]
        )
    }

    func testTableBecomesGrid() {
        let md = "| Metric | Proteus | Terminal |\n|---|---|---|\n| First-turn | 19k | 43k |\n| Average | 79k | 143k |"
        XCTAssertEqual(MarkdownBlocks.parse(md), [
            .table(
                header: ["Metric", "Proteus", "Terminal"],
                rows: [["First-turn", "19k", "43k"], ["Average", "79k", "143k"]]
            ),
        ])
    }

    func testTableWithoutOuterPipesAndEscapedPipe() {
        let md = "a | b\n--- | ---\nx \\| y | z"
        XCTAssertEqual(MarkdownBlocks.parse(md), [
            .table(header: ["a", "b"], rows: [["x | y", "z"]]),
        ])
    }

    func testTableEndsAtBlankLine() {
        let md = "| a | b |\n|---|---|\n| 1 | 2 |\n\nAfter."
        let blocks = MarkdownBlocks.parse(md)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.last, .paragraph("After."))
    }

    func testRuleAndQuote() {
        XCTAssertEqual(MarkdownBlocks.parse("a\n\n---\n\n> quoted\n> more"), [
            .paragraph("a"), .rule, .quote("quoted\nmore"),
        ])
    }

    func testInlineBoldAndCodeLeaveNoMarkup() {
        let text = String(MarkdownBlocks.inline("**Cache misses:** see `/tmp`").characters)
        XCTAssertEqual(text, "Cache misses: see /tmp")
    }
}
