import XCTest
@testable import ClaudeBridgeCore

final class OutlineTests: XCTestCase {
    func outline(_ source: String, width: Double = 466, height: Double = 678) -> BridgeOutline {
        BridgeOutline(tree: BridgeUITree(source: source), map: .identity, screenWidth: width, screenHeight: height)
    }

    // MARK: What a read looks like

    func testChatReadsAsRegionsAndRows() {
        XCTAssertEqual(outline(OutlineFixtures.chat).text(), #"""
        WhatsApp · 466x678
        Top
          e1 "Profile picture" = "View contact info" (37,48)
          e2 button "Alex" = "online" (224,48)
        List #ChatMessagesTableView · 6 rows, 3 on screen
          r1 "Your message, see you at 7, 10 November at 12:09, Sent to Alex, Read"
          r2 [e3 button "HD"] · "Forwarded.\nPhoto, 10 November at 12:13, Received from Alex" · [e4 button "Forward"]
          r3 "Your message, Ok, 10 November at 12:14, Sent to Alex, Read"
          r4 "Today" (191,103)
          r5 "message, Plan for Saturday\n•  Meet at the court, 9am.\n•  Bring two tubes, one spare racket.\n\n•  Lunch after, if it's not raining., 09:58, Received from Alex" (233,267)
          r6 "Your message, Sounds good, 10:09, Sent to Alex, Delivered" (233,557)
        Toolbar
          e5 button "49" #BackButton (418,198)
          e6 button "Start video call with Alex" (418,258)
        Bottom
          e7 button "Share media" (36,618)
          e8 text field "Compose message" empty (167,618)
          e9 button "Camera" (298,618)
        """#)
    }

    func testScaffoldingIsLeftOut() {
        let text = outline(OutlineFixtures.chat).text()
        for scaffolding in ["Toolbar\"", "Wallpaper", "Doodle", "scroll bar", "grabber", "TextSelection",
                            "MessageStatusSliceView", "\u{200E}", "mediaDownloadSmall"] {
            XCTAssertFalse(text.contains(scaffolding), scaffolding)
        }
        // Said once, by the control: not again by its container, the title or the caption.
        XCTAssertEqual(text.components(separatedBy: "\"Alex\"").count - 1, 1)
        XCTAssertEqual(text.components(separatedBy: "\"Share media\"").count - 1, 1)
        XCTAssertEqual(text.components(separatedBy: "\"online\"").count - 1, 1)
    }

    func testLongMenuReadStaysInBudgetAndNamesWhatIsLeftOut() {
        let menu = outline(OutlineFixtures.menu(), width: 393, height: 852)
        let text = menu.text()
        XCTAssertLessThanOrEqual(text.count, BridgeOutline.Selection().budget + 200)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines[1], "Top", "the top bar comes first, though the tree lists it after the menu")
        XCTAssertTrue(text.contains("List #food_merchant_menu_tableView · 134 rows, 9 on screen"), text)
        // Everything on screen, in full.
        XCTAssertTrue(text.contains("r2 [e3 button \"Group Order\" disabled (70,195)] · [e4 button \"Share\" (180,195)] (197,195)"))
        XCTAssertTrue(text.contains("r4 \"Dish 1 Meal\" · \"Crispy, juicy and served with \\\"house\\\" sauce.\" · \"5.50\" · [e5 button \"Add\" (355,325)] (197,290)"), text)
        // Rows further down, without a tap point, then a pointer to the rest.
        XCTAssertTrue(text.contains("\n  r10 \"Dish 7 Meal\""))
        let more = try! XCTUnwrap(lines.first { $0.contains("rows not shown") })
        XCTAssertTrue(more.hasSuffix("-r134): read_ui rows:\"" + more.components(separatedBy: "rows:\"")[1]), more)
        // The basket bar keeps the total that sits inside its button.
        XCTAssertTrue(text.hasSuffix("Bottom\n  e125 button \"View basket\" · \"S$0.00\" (197,805)"), String(text.suffix(200)))
        // The quantity stepper nested in each Add button says nothing of its own.
        XCTAssertFalse(text.contains("\"0\""))
        // An off-screen category header has no tap point: its text reports a
        // bogus frame, and its own row frame is used instead.
        XCTAssertTrue(text.contains("\n  r14 \"Category 2\"\n"), text)
    }

    func testRowsReadPicksUpWhereThePageLeftOff() {
        let menu = outline(OutlineFixtures.menu(), width: 393, height: 852)
        var selection = BridgeOutline.Selection()
        selection.mode = .rows(60...134)
        let text = menu.text(selection)
        XCTAssertTrue(text.contains("\n  r60 "))
        XCTAssertTrue(text.contains("\n  r134 "))
        XCTAssertFalse(text.contains("\n  r59 "))
        XCTAssertFalse(text.contains("Top\n"), "only the rows asked for")
        // A range too long for one result is split at a row, with the rest named.
        selection.budget = 2000
        let short = menu.text(selection)
        let more = try! XCTUnwrap(short.components(separatedBy: "\n").last)
        XCTAssertTrue(more.contains("rows not shown (r"), more)
        XCTAssertTrue(more.hasSuffix("-r134\""), more)
    }

    func testVisibleOnlyAndFilter() {
        let menu = outline(OutlineFixtures.menu(), width: 393, height: 852)
        var selection = BridgeOutline.Selection()
        selection.mode = .visible
        let visible = menu.text(selection)
        XCTAssertTrue(visible.contains("r9 \"Dish 6 Meal\""))
        XCTAssertFalse(visible.contains("Dish 7 Meal"))
        XCTAssertTrue(visible.contains("125 rows not shown (r10-r134)"))
        selection.mode = .filter("dish 11 ")
        let filtered = menu.text(selection)
        XCTAssertTrue(filtered.contains("r15 \"Dish 11 Meal\""), filtered)
        XCTAssertFalse(filtered.contains("Dish 1 Meal"))
        selection.mode = .filter("nothing like this")
        XCTAssertTrue(menu.text(selection).contains("Nothing on this screen contains that text."))
    }

    func testVisibleOnlyNamesEveryGap() {
        // A sticky date header stays on screen while the rows after it have scrolled away.
        let source = [
            "Application, label: 'Chat', {{0, 0}, {400, 800}}",
            "  Table, {{0, 0}, {400, 800}}",
            "    StaticText, label: 'Yesterday', {{150, 90}, {100, 20}}",
            "    Cell, {{0, -300}, {400, 100}}",
            "      StaticText, label: 'Gone by', {{10, -290}, {300, 20}}",
            "    Cell, {{0, 300}, {400, 100}}",
            "      StaticText, label: 'Showing', {{10, 310}, {300, 20}}",
            "    Cell, {{0, 1300}, {400, 100}}",
            "      StaticText, label: 'Below', {{10, 1310}, {300, 20}}",
        ].joined(separator: "\n")
        var selection = BridgeOutline.Selection()
        selection.mode = .visible
        let text = outline(source, width: 400, height: 800).text(selection)
        XCTAssertTrue(text.contains("""
          r1 "Yesterday" (200,100)
          … 1 row not shown (r2): read_ui rows:"r2"
          r3 "Showing" (200,350)
          ↓ 1 row not shown (r4): read_ui rows:"r4"
        """), text)
    }

    func testStackedAndNestedControlsSayItOnce() {
        // Shaped like Grab's home: a card cell whose button says the same with
        // its value, and an account button drawn twice in the same place.
        let source = [
            "Application, label: 'Grab', {{0, 0}, {393, 852}}",
            "  Button, label: 'Account', {{320, 30}, {50, 40}}",
            "  Other, id: 'account_button', {{320, 30}, {50, 40}}",
            "    StaticText, label: 'Account', {{320, 30}, {50, 40}}",
            "  Cell, label: 'Finance S$0.55', {{10, 300}, {150, 80}}",
            "    Button, label: 'Finance', value: 'S$0.55', {{10, 300}, {150, 80}}",
        ].joined(separator: "\n")
        let text = outline(source, width: 393, height: 852).text()
        XCTAssertEqual(text.components(separatedBy: "\"Account\"").count - 1, 1, text)
        XCTAssertTrue(text.contains("button \"Finance\" = \"S$0.55\""), text)
        XCTAssertFalse(text.contains("Finance S$0.55"), text)
    }

    func testARowListedLastButDrawnOnScreenDoesNotPullInTheWholeList() {
        // Like Grab's menu: 150 dishes, the first three on screen, and a promo
        // strip the app lists after all of them but draws near the top.
        var lines = ["Application, label: 'Grab', {{0, 0}, {393, 852}}", "  Table, {{0, 0}, {393, 852}}"]
        for i in 0..<150 {
            lines.append("    Cell, {{0, \(400 + i * 120)}, {393, 120}}")
            lines.append("      StaticText, label: 'Dish \(i + 1) with a fairly long description of what is in it', {{0, 0}, {300, 20}}")
        }
        // Four small labels, listed last, drawn over the top: more rows on
        // screen than the three dishes, but far less of the screen.
        for (i, label) in ["Up to 15% off", "Group Order", "Share", "Min. spend"].enumerated() {
            lines.append("    StaticText, label: '\(label)', {{40, \(330 - i * 30)}, {120, 20}}")
        }
        let menu = outline(lines.joined(separator: "\n"), width: 393, height: 852)
        var selection = BridgeOutline.Selection()
        selection.budget = 3000
        let text = menu.text(selection)
        XCTAssertLessThanOrEqual(text.count, 3200, text)
        XCTAssertTrue(text.contains("  r1 \"Dish 1 "), text)
        XCTAssertTrue(text.contains("not shown (r"), text)
        XCTAssertTrue(text.contains("  … "), "the gap before the strip is named: \(text)")
        XCTAssertTrue(text.contains("  r151 \"Up to 15% off\" (100,340)"), text)
        XCTAssertTrue(text.hasSuffix("  r154 \"Min. spend\" (100,250)"), text)
        XCTAssertTrue(text.contains("  r4 \"Dish 4 "), "it grew from the dishes: \(text)")
    }

    // MARK: Refs

    func testRefsAreTheSameInEveryRead() {
        let first = outline(OutlineFixtures.chat)
        let second = outline(OutlineFixtures.chat)
        XCTAssertEqual(first.allItems.map(\.ref), second.allItems.map(\.ref))
        XCTAssertEqual(first.allItems.map(\.key), second.allItems.map(\.key))
        let forward = try! XCTUnwrap(first.item(ref: "e4"))
        XCTAssertEqual(forward.text, "Forward")
        XCTAssertEqual(second.match(kind: forward.kind, key: forward.key, occurrence: forward.occurrence)?.ref, "e4")
    }

    func testSameLookingItemsAreToldApartByOccurrence() {
        let menu = outline(OutlineFixtures.menu(dishes: 14), width: 393, height: 852)
        // "Dish 1 Meal" and "Dish 8 Meal" both cost 5.50 but are different rows;
        // every Add button is told apart by the row it sits in.
        let adds = menu.allItems.filter { $0.text == "Add" }
        XCTAssertEqual(adds.count, 14)
        XCTAssertEqual(Set(adds.map(\.key)).count, 14)
        XCTAssertTrue(adds.allSatisfy { $0.occurrence == 1 })
    }

    // MARK: Parsing

    /// Labels made of the characters that break naive parsing, written the
    /// way the device writes them, come back exactly.
    func testParserRoundTripsAwkwardText() {
        var generator = SystemRandomNumberGenerator()
        let pieces = ["a", "B", " ", ",", ", ", "'", "''", "\"", "{", "}", "{{", "}}", "{{1, 2}, {3, 4}}", ", disabled",
                      ", selected", "\\", "é", "😀", "\u{200E}", ": ", "label: ", "id", "\n", "\n\n"]
        func randomText() -> String {
            (0..<Int.random(in: 0...12, using: &generator)).map { _ in pieces.randomElement(using: &generator)! }.joined()
        }
        for round in 0..<500 {
            let label = randomText(), value = randomText(), identifier = randomText()
            // A label that itself contains "', value: '" or "', id: '" cannot be
            // told from a field boundary; the device never escapes, so neither can we.
            // (With its closing quote: a label ending in "', id: " is the same case.)
            if [label + "'", value + "'"].contains(where: { $0.contains("', value: '") || $0.contains("', id: '") }) { continue }
            let disabled = Bool.random(using: &generator), selected = Bool.random(using: &generator)
            var line = "    Button"
            if !label.isEmpty { line += ", label: '\(label)'" }
            if !value.isEmpty { line += ", value: '\(value)'" }
            if !identifier.isEmpty, !identifier.contains("\n") { line += ", id: '\(identifier)'" }
            if disabled { line += ", disabled" }
            if selected { line += ", selected" }
            line += ", {{12, -34}, {56, 78}}"
            let source = "Application, label: 'A', {{0, 0}, {10, 10}}\n" + line
            // A line inside a label that happens to end like a frame would be
            // taken for the end of the element; the device's text has the same limit.
            let frameAtEnd = #"\{\{-?[0-9.]+, -?[0-9.]+\}, \{-?[0-9.]+, -?[0-9.]+\}\}$"#
            if line.components(separatedBy: "\n").dropLast().contains(where: { $0.range(of: frameAtEnd, options: .regularExpression) != nil }) { continue }
            let tree = BridgeUITree(source: source)
            XCTAssertEqual(tree.nodes.count, 2, "round \(round): \(line.debugDescription)")
            guard tree.nodes.count == 2 else { continue }
            let node = tree.nodes[1]
            func shown(_ s: String) -> String? { s.isEmpty ? nil : s.replacingOccurrences(of: "\n", with: "\\n") }
            XCTAssertEqual(node.label, shown(label), "round \(round): \(line)")
            XCTAssertEqual(node.value, shown(value), "round \(round): \(line)")
            if !identifier.contains("\n") { XCTAssertEqual(node.identifier, shown(identifier), "round \(round): \(line)") }
            XCTAssertEqual(node.disabled, disabled, "round \(round): \(line)")
            XCTAssertEqual(node.selected, selected, "round \(round): \(line)")
            XCTAssertEqual(node.frame, .init(x: 12, y: -34, width: 56, height: 78))
            XCTAssertEqual(node.parent, 0)
        }
    }

    func testParserSkipsWhatIsNotAnElement() {
        let tree = BridgeUITree(source: "Some note from the device\nApplication, label: 'A', {{0, 0}, {10, 10}}\n\n  not a line, {{1, 2}, {3, 4}} trailing")
        XCTAssertEqual(tree.nodes.map(\.type), ["Application"])
        XCTAssertEqual(outline("Ignore everything").text(), "App · 466x678\n(nothing readable on screen)")
    }
}
