import Foundation
import XCTest
@testable import KokoroCore

final class MessageMarkdownTests: XCTestCase {
    func testRendersBlockMarkdown() {
        let content = MessageMarkdown.attributedString(for: """
        # Heading

        - First
        - Second

        > Quoted

        ```swift
        let value = 1
        ```

        | Name | Value |
        | --- | --- |
        | Sample | 42 |
        """)

        XCTAssertTrue(hasBlock(content) { if case .header(level: 1) = $0 { return true }; return false })
        XCTAssertTrue(hasBlock(content) { if case .unorderedList = $0 { return true }; return false })
        XCTAssertTrue(hasBlock(content) { if case .blockQuote = $0 { return true }; return false })
        XCTAssertTrue(hasBlock(content) { if case .codeBlock(languageHint: "swift") = $0 { return true }; return false })
        XCTAssertTrue(hasBlock(content) { if case .table = $0 { return true }; return false })
    }

    func testPreservesChatNewlinesAndInlineFormatting() {
        let content = MessageMarkdown.attributedString(for: "first\n**second**\nthird  \nfourth")

        XCTAssertEqual(String(content.characters), "first\nsecond\nthird\nfourth")
        XCTAssertTrue(content.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertEqual(content.runs.filter { $0.inlinePresentationIntent?.contains(.lineBreak) == true }.count, 3)
        XCTAssertFalse(content.runs.contains { $0.inlinePresentationIntent?.contains(.softBreak) == true })
    }

    func testReferenceLabelsRemainLiteralMarkdown() {
        let content = MessageMarkdown.attributedString(for: "<#CHANNEL|# heading *stars* [link](https://example.test) `code`>\n<@USER|user_name>")

        XCTAssertEqual(String(content.characters), "## heading *stars* [link](https://example.test) `code`\n@user_name")
        XCTAssertFalse(hasBlock(content) { if case .header = $0 { return true }; return false })
        XCTAssertFalse(content.runs.contains { $0.link != nil })
        XCTAssertFalse(content.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        XCTAssertFalse(content.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    }

    func testReferenceLabelDoesNotCreateExtraTableCells() {
        let content = MessageMarkdown.attributedString(for: """
        | Channel | Description |
        | --- | --- |
        | <#CHANNEL|one | two> | A channel |
        """)

        XCTAssertTrue(String(content.characters).contains("#one | two"))
        XCTAssertTrue(hasBlock(content) { if case .table(let columns) = $0 { return columns.count == 2 }; return false })
    }

    func testCodePreservesReferencesAndImageSyntax() {
        let source = """
        `<@USER|user_name> ![alt](https://example.test/a.png)`

        ```text
        <#CHANNEL|*literal*>
        ![](https://example.test/b.png)
        ```
        """
        let content = MessageMarkdown.attributedString(for: source)

        XCTAssertTrue(String(content.characters).contains("<@USER|user_name> ![alt](https://example.test/a.png)"))
        XCTAssertTrue(String(content.characters).contains("<#CHANNEL|*literal*>\n![](https://example.test/b.png)"))
        XCTAssertFalse(content.runs.contains { $0.imageURL != nil || $0.link != nil })
    }

    func testImagesBecomeLinksWithoutBypassingEmbedExpansionAndSensitiveMediaControls() {
        let content = MessageMarkdown.attributedString(for: "![Image](https://example.test/a.png) ![](https://example.test/b.png)")

        XCTAssertEqual(String(content.characters), "Image https://example.test/b.png")
        XCTAssertFalse(content.runs.contains { $0.imageURL != nil }, "Textual must not load a second image outside the embed view's gates")
        XCTAssertEqual(content.runs.compactMap { $0.link?.absoluteString }, ["https://example.test/a.png", "https://example.test/b.png"])
    }

    func testPreservesLinkDestinationsIncludingLinkedImages() {
        let content = MessageMarkdown.attributedString(for: "[Website](https://example.test/page) [![Image](https://example.test/a.png)](https://example.test/destination)")

        XCTAssertEqual(String(content.characters), "Website Image")
        XCTAssertEqual(content.runs.compactMap { $0.link?.absoluteString }, ["https://example.test/page", "https://example.test/destination"])
        XCTAssertFalse(content.runs.contains { $0.imageURL != nil })
    }

    func testReferencePlaceholderCannotAlterExistingText() {
        let content = MessageMarkdown.attributedString(for: "KOKOROREFERENCE0END <#CHANNEL|general> <@USER|person>")

        XCTAssertEqual(String(content.characters), "KOKOROREFERENCE0END #general @person")
    }

    func testEmojiShortcodesRenderInMessageTextAndKeepMarkdownAttributes() {
        let content = MessageMarkdown.attributedString(for: "🎈 おめでとう :tada: **:wave:** [見てね :eyes:](https://example.test)")

        XCTAssertEqual(String(content.characters), "🎈 おめでとう 🎉 👋 見てね 👀")
        XCTAssertTrue(content.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true && String(content[$0.range].characters) == "👋" })
        XCTAssertTrue(content.runs.contains { $0.link?.absoluteString == "https://example.test" && String(content[$0.range].characters) == "見てね 👀" })
    }

    func testEmojiShortcodesRemainLiteralInCodeAndUnknownNames() {
        let content = MessageMarkdown.attributedString(for: """
        :tada: :not_an_emoji:

        `:wave:`

        ```text
        :eyes:
        ```
        """)

        XCTAssertTrue(String(content.characters).contains("🎉 :not_an_emoji:"))
        XCTAssertTrue(String(content.characters).contains(":wave:"))
        XCTAssertTrue(String(content.characters).contains(":eyes:"))
    }

    func testEmojiSkinToneShortcode() {
        let content = MessageMarkdown.attributedString(for: "ありがとう :pray::skin-tone-6:")

        XCTAssertEqual(String(content.characters), "ありがとう 🙏🏿")
    }

    private func hasBlock(_ content: AttributedString, matching predicate: (PresentationIntent.Kind) -> Bool) -> Bool {
        content.runs.contains { run in
            run.presentationIntent?.components.contains { predicate($0.kind) } == true
        }
    }
}
