import XCTest
@testable import ClaudeBridgeCore

/// Labels with line breaks in them (a WhatsApp message of several lines)
/// arrive from the device spread over several lines of the tree text.
final class MultiLineLabelTests: XCTestCase {
    /// As the device sends it: the bubble's label runs over four lines and
    /// its last line holds a comma, the time and the frame.
    let chat = [
        "Application, label: 'WhatsApp', {{0, 0}, {466, 678}}",
        "  Table, {{0, 0}, {466, 678}}",
        "    Cell, id: 'bubble', {{0, -130}, {466, 663}}",
        "      Other, label: 'message, Court booking",
        "•  Saturday 9am, court 3.",
        "",
        "•  Bring water, two tubes and a spare grip., 09:58, Received from Alex', {{16, -124}, {279, 651}}",
        "        Other, id: 'status', {{16, 507}, {279, 19}}",
        "    Cell, id: 'bubble', {{0, 532}, {466, 50}}",
        "      Other, label: 'Your message, Ok, 10:09, Sent to Alex', {{262, 538}, {104, 38}}",
    ].joined(separator: "\n")

    let fullMessage = "message, Court booking\\n•  Saturday 9am, court 3.\\n\\n"
        + "•  Bring water, two tubes and a spare grip., 09:58, Received from Alex"

    func testSpilledLinesAreJoinedIntoOneElement() {
        let joined = BridgeSourceLines.join(chat)
        XCTAssertEqual(joined.components(separatedBy: "\n").count, 7, joined)
        let tree = BridgeUITree(source: joined)
        XCTAssertEqual(tree.nodes.map(\.type), ["Application", "Table", "Cell", "Other", "Other", "Cell", "Other"])
        let bubble = tree.nodes[3]
        XCTAssertEqual(bubble.label, fullMessage)
        XCTAssertEqual(bubble.frame, BridgeUITree.Rect(x: 16, y: -124, width: 279, height: 651))
        XCTAssertEqual(bubble.parent, 2)
        XCTAssertEqual(tree.nodes[4].parent, 3, "the next line is the bubble's child again")
    }

    func testTextWithoutSpillsIsUntouched() {
        let plain = "Application, label: 'A', {{0, 0}, {10, 10}}\n  Button, label: 'Go, now', {{1, 2}, {3, 4}}"
        XCTAssertEqual(BridgeSourceLines.join(plain), plain)
        // A line that opens a label but never reaches a frame is left as it was.
        let broken = "Application, label: 'A', {{0, 0}, {10, 10}}\n  Other, label: 'cut off\nmore"
        XCTAssertEqual(BridgeSourceLines.join(broken), broken)
    }

    func testWindowsLineEndingsInsideALabel() {
        let source = "Application, {{0, 0}, {10, 10}}\n  Other, label: 'one\r\ntwo', {{1, 2}, {3, 4}}"
        XCTAssertEqual(BridgeUITree(source: BridgeSourceLines.join(source)).nodes[1].label, "one\\ntwo")
    }

    func testReadUIShowsTheWholeMessage() {
        let h = Harness()
        h.raw.foreground = whatsApp
        h.raw.results["page_source"] = .success(["source": chat])
        let text = h.call("read_ui").firstText
        // One line, under its cell, followed by its frame.
        XCTAssertTrue(text.contains("\n   O '\(fullMessage)' 13,-105,"), text)
        XCTAssertTrue(text.contains("\\n inside a label or value is a line break"), text)
        XCTAssertFalse(text.contains("label: '"), "no line falls through unparsed: \(text)")
    }

    func testNoLineBreakNoteWhenThereAreNone() {
        let h = Harness()
        h.raw.foreground = whatsApp
        h.raw.results["page_source"] = .success(["source": "Application, label: 'A', {{0, 0}, {466, 678}}"])
        XCTAssertFalse(h.call("read_ui").firstText.contains("is a line break"))
    }

    func testElementLookupsMatchTheTextAsShown() {
        let h = Harness()
        h.raw.foreground = whatsApp
        h.raw.results["page_source"] = .success(["source": chat])
        var asked: [String] = []
        h.tools.isHittable = { _, text, _, _ in asked.append(text); return true }
        let shown = "Your message, Ok, 10:09, Sent to Alex"
        XCTAssertTrue(h.call("check_element", ["text": shown]).firstText.contains("On screen: yes"))
        // The bridge's own tree has the label as read_ui shows it…
        let text = h.call("check_element", ["text": "court 3.\\n\\n•  Bring water", "match": "contains"]).firstText
        XCTAssertTrue(text.contains("check_element: found"), text)
        // …and the device, which has the real line breaks, is asked with those.
        XCTAssertEqual(asked.last, "court 3.\n\n•  Bring water")
        // The filter is applied on the device, so it gets real line breaks too.
        _ = h.call("read_ui", ["filter_text": "court 3.\\n"])
        let filter = h.raw.calls.last { $0.method == "page_source" && $0.params["filter"] != nil }?.params["filter"] as? BridgeJSON
        XCTAssertEqual(filter?["text"] as? String, "court 3.\n")
    }
}
