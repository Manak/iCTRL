import Foundation

/// Text from the screen, made fit to show.
enum BridgeText {
    /// Without invisible direction marks and zero-width spaces (WhatsApp puts
    /// one in front of nearly every label), and trimmed. The joiners that
    /// hold emoji together are kept.
    static func clean(_ text: String?) -> String {
        guard let text = text, !text.isEmpty else { return "" }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !isInvisible(scalar) { scalars.append(scalar) }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200B, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF: return true
        default: return false
        }
    }

    /// Longest text shown for one element; the rest is counted, not shown.
    static let maxShown = 4000

    /// In double quotes, inner double quotes escaped.
    static func quoted(_ text: String) -> String {
        var body = text
        var extra = ""
        if body.count > maxShown {
            extra = "…(+\(body.count - maxShown) characters)"
            body = String(body.prefix(maxShown))
        }
        return "\"" + body.replacingOccurrences(of: "\"", with: "\\\"") + "\"" + extra
    }
}

/// read_ui's picture of a screen.
///
/// Built from the parsed tree in one pass, and only then turned into text.
/// It keeps what a reader needs and leaves out the scaffolding:
/// - the screen is split into regions: the top, each scrolling list, the
///   bottom, bars, alerts;
/// - each list row is one item, holding the row's texts and the controls
///   inside it;
/// - unnamed containers, scroll bars and text-selection handles are left
///   out, as are invisible direction marks;
/// - text shown by an element is not shown again by its containers or by
///   a sibling that repeats it, and where a container and a control inside
///   it say the same thing, the control is kept;
/// - each item gets a ref (e3, r12) that the element tools accept, and a tap
///   point when it is on screen.
struct BridgeOutline {
    struct Point: Equatable {
        var x: Double
        var y: Double
    }

    enum Kind: Equatable { case element, row }

    struct Item {
        var ref = ""
        let kind: Kind
        /// Tree index of the node to act on.
        let node: Int
        /// "button", "text field", …; empty for plain text.
        let role: String
        let isControl: Bool
        let text: String
        let value: String
        /// Other words inside a control, besides its label (a price on a
        /// basket button). Shown, but not part of `key`: they change.
        var detail: [String] = []
        /// Shown only for a control whose text says nothing by itself.
        let identifier: String
        let states: [String]
        /// Where to tap it, in screen points; nil when it is off screen.
        let point: Point?
        /// How much of its height shows, in the app's points (rows only).
        var shownHeight = 0.0
        /// A row's contents, in reading order.
        var parts: [Part] = []
        /// What the item is, apart from where it is: finds it again in a
        /// later read of the same screen, together with `occurrence`.
        var key: String
        var occurrence = 0

        var controls: [Item] {
            parts.compactMap { if case .control(let c) = $0 { return c } else { return nil } }
        }

        /// The text a filter looks at.
        var searchText: String {
            var all = [text, value, identifier] + detail
            for part in parts {
                switch part {
                case .text(let t): all.append(t)
                case .control(let c): all.append(c.searchText)
                }
            }
            return all.filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    enum Part {
        case text(String)
        case control(Item)
    }

    struct Region {
        let title: String
        let isList: Bool
        var items: [Item]
    }

    let appName: String
    let screenWidth: Double
    let screenHeight: Double
    var regions: [Region]
    var keyboardShowing = false

    /// Every item, the controls inside rows included, in reading order.
    var allItems: [Item] {
        regions.flatMap(\.items).flatMap { [$0] + $0.controls }
    }

    func item(ref: String) -> Item? {
        allItems.first { $0.ref == ref }
    }

    /// The item that is the same as one from an earlier read.
    func match(kind: Kind, key: String, occurrence: Int) -> Item? {
        allItems.first { $0.kind == kind && $0.key == key && $0.occurrence == occurrence }
    }

    static let listTypes: Set<String> = ["Table", "CollectionView", "ScrollView", "WebView"]

    init(tree: BridgeUITree, map: BridgeCoordinateMap, screenWidth: Double, screenHeight: Double) {
        var builder = OutlineBuilder(tree: tree, map: map, screenHeight: screenHeight)
        let built = builder.build()
        appName = tree.nodes.first.map { tree.text(of: $0) } ?? ""
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        regions = built.regions
        keyboardShowing = built.keyboard
        numberItems()
    }

    /// Refs and occurrence counts, in reading order.
    private mutating func numberItems() {
        var elements = 0, rows = 0
        var seen: [String: Int] = [:]
        func number(_ item: inout Item, prefix: String) {
            if item.kind == .row {
                rows += 1
                item.ref = "r\(rows)"
            } else {
                elements += 1
                item.ref = "e\(elements)"
            }
            item.key = prefix + item.key
            seen[item.key, default: 0] += 1
            item.occurrence = seen[item.key]!
        }
        for r in regions.indices {
            for i in regions[r].items.indices {
                number(&regions[r].items[i], prefix: "")
                let rowKey = regions[r].items[i].key
                for p in regions[r].items[i].parts.indices {
                    guard case .control(var control) = regions[r].items[i].parts[p] else { continue }
                    number(&control, prefix: rowKey + " › ")
                    regions[r].items[i].parts[p] = .control(control)
                }
            }
        }
    }
}

/// Walks the tree once and sorts what it finds into regions.
private struct OutlineBuilder {
    enum Area: Hashable {
        case alert, sheet, top, screen, list(Int), toolbar, tabBar, bottom
    }

    enum Emission {
        case item(BridgeOutline.Item, Area)
        /// Words in a row, and where they show (nil off screen).
        case text(String, BridgeOutline.Point?)
        case list(Int)
    }

    static let bars: [String: Area] = [
        "NavigationBar": .top, "TabBar": .tabBar, "Toolbar": .toolbar, "Alert": .alert, "Sheet": .sheet,
    ]
    static let roles: [String: String] = [
        "Button": "button", "Link": "link", "TextField": "text field", "SecureTextField": "password field",
        "SearchField": "search field", "TextView": "text field", "Switch": "switch", "Slider": "slider",
        "SegmentedControl": "segmented control", "Cell": "cell", "Image": "image", "Icon": "app icon",
        "PickerWheel": "picker", "Picker": "picker", "Key": "key",
    ]
    static let textInputs: Set<String> = ["TextField", "SecureTextField", "SearchField", "TextView"]

    let tree: BridgeUITree
    let map: BridgeCoordinateMap
    let screenHeight: Double
    var keyboard = false

    var nodes: [BridgeUITree.Node] { tree.nodes }

    mutating func build() -> (regions: [BridgeOutline.Region], keyboard: Bool) {
        guard !nodes.isEmpty else { return ([], false) }
        var scope: [String] = []
        var emissions: [Emission] = []
        for child in tree.children[0] {
            walk(child, area: .screen, inRow: false, scope: &scope, out: &emissions)
        }

        var order: [Area] = []
        var items: [Area: [BridgeOutline.Item]] = [:]
        func add(_ item: BridgeOutline.Item, to area: Area) {
            if items[area] == nil { order.append(area) }
            items[area, default: []].append(item)
        }
        for emission in emissions {
            switch emission {
            case .item(let item, let area):
                add(item, to: placed(area, item.point))
            case .list(let list):
                for row in rows(of: list) {
                    if let item = rowItem(row) { add(item, to: .list(list)) }
                }
            case .text:
                break
            }
        }
        // In the order they appear on screen: alerts and sheets (on top of
        // everything), the top, the content, then the bars at the bottom.
        func rank(_ area: Area) -> Int {
            switch area {
            case .alert, .sheet: return 0
            case .top: return 1
            case .screen, .list: return 2
            case .toolbar: return 3
            case .tabBar, .bottom: return 4
            }
        }
        order = order.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        let regions = order.map { area in
            BridgeOutline.Region(title: title(of: area), isList: { if case .list = area { return true }; return false }(),
                                 items: items[area] ?? [])
        }
        return (regions, keyboard)
    }

    // MARK: Walking

    mutating func walk(_ i: Int, area: Area, inRow: Bool, scope: inout [String], out: inout [Emission]) {
        let node = nodes[i]
        if skipped(node) { return }
        if node.type == "Keyboard" {
            keyboard = true
            return
        }
        var area = area
        if !inRow, let bar = Self.bars[node.type] { area = bar }
        if !inRow, BridgeOutline.listTypes.contains(node.type) {
            out.append(.list(i))
            return
        }
        var inner = scope
        if let item = element(i, scope: scope) {
            let said = [item.text, item.value].filter { !$0.isEmpty }
            scope += said
            inner += said
            if inRow && !item.isControl {
                said.forEach { out.append(.text($0, item.point)) }
            } else if !Self.repeats(item, in: out) {
                out.append(.item(item, area))
            }
            if item.isControl {
                // What is inside a control is the control: only further
                // controls with words of their own are listed.
                for child in tree.children[i] { nestedControls(child, under: item.text, area: area, out: &out) }
                return
            }
        }
        for child in tree.children[i] {
            walk(child, area: area, inRow: inRow, scope: &inner, out: &out)
        }
    }

    func nestedControls(_ i: Int, under parentText: String, area: Area, out: inout [Emission]) {
        let node = nodes[i]
        if skipped(node) { return }
        let text = tree.text(of: node)
        if BridgeTappableHint.isControl(node), text.contains(where: \.isLetter),
           text.caseInsensitiveCompare(parentText) != .orderedSame,
           let item = element(i, scope: [parentText]), !Self.repeats(item, in: out) {
            out.append(.item(item, area))
        }
        for child in tree.children[i] { nestedControls(child, under: parentText, area: area, out: &out) }
    }

    /// The item a node shows as, or nil when it shows nothing of its own.
    func element(_ i: Int, scope: [String]) -> BridgeOutline.Item? {
        let node = nodes[i]
        var text = tree.text(of: node)
        let value = shownValue(node, text: text)
        let control = BridgeTappableHint.isControl(node)
        if !control {
            if text.isEmpty && value.isEmpty { return nil }
            if covered(text, scope) && covered(value, scope) { return nil }
            // A container and a control inside it saying the same: the control speaks.
            if !text.isEmpty, hasControl(below: i, saying: text) { return nil }
            return item(i, control: false, text: covered(text, scope) ? "" : text, value: value, identifier: "")
        }
        if text.isEmpty { text = folded(i) }
        if !text.isEmpty, hasControl(below: i, saying: text) { return nil }
        let identifier = BridgeText.clean(node.identifier)
        if text.isEmpty && value.isEmpty && identifier.isEmpty { return nil }
        // An identifier helps only when the text does not say what it is ("49").
        let showID = !text.contains(where: \.isLetter)
        var made = item(i, control: true, text: text, value: value, identifier: showID ? identifier : "")
        made.detail = detail(i, besides: [text, value])
        return made
    }

    /// Words inside a control that its label does not already say, leaving
    /// out controls nested in it (they are listed on their own).
    func detail(_ i: Int, besides said: [String]) -> [String] {
        var words: [String] = []
        var stack = Array(tree.children[i].reversed())
        while let j = stack.popLast(), words.count < 3 {
            let node = nodes[j]
            if skipped(node) || BridgeTappableHint.isControl(node) { continue }
            let text = tree.text(of: node)
            if !text.isEmpty, !(said + words).contains(where: { $0.contains(text) }) { words.append(text) }
            stack += tree.children[j].reversed()
        }
        return words
    }

    func item(_ i: Int, control: Bool, text: String, value: String, identifier: String) -> BridgeOutline.Item {
        let node = nodes[i]
        var states: [String] = []
        if node.disabled { states.append("disabled") }
        if node.selected { states.append("selected") }
        if Self.textInputs.contains(node.type), value.isEmpty { states.append("empty") }
        var role = Self.roles[node.type] ?? ""
        if role.isEmpty, control {
            let words = (node.identifier ?? "").lowercased().split(whereSeparator: { !$0.isLetter })
            role = words.contains("tab") ? "tab" : "button"
        }
        return BridgeOutline.Item(kind: .element, node: i, role: role, isControl: control, text: text, value: value,
                                  identifier: identifier, states: states, point: point(of: i),
                                  key: "\(node.type)|\(text)|\(BridgeText.clean(node.identifier))")
    }

    // MARK: Lists

    /// The rows of a list: its children, looking through wrappers that only
    /// hold other elements.
    func rows(of list: Int) -> [Int] {
        let listHeight = max(1, nodes[list].frame.height)
        var out: [Int] = []
        func gather(_ i: Int, siblings: Int) {
            let node = nodes[i]
            if skipped(node) { return }
            let kids = tree.children[i]
            let isList = BridgeOutline.listTypes.contains(node.type)
            let plain = node.type != "Cell" && !isList && !BridgeTappableHint.isControl(node)
                && tree.text(of: node).isEmpty && BridgeText.clean(node.value).isEmpty
            if plain {
                if kids.isEmpty { return }
                // The list's content area: the only thing in its parent, or
                // much taller than the list. Anything else is a row, and
                // keeps its own frame (the children of an off-screen row
                // can report a bogus one).
                if siblings == 1 || node.frame.height >= listHeight * 1.5 {
                    kids.forEach { gather($0, siblings: kids.count) }
                    return
                }
            }
            // A list inside the list that is as tall as a screen holds rows of its own.
            if isList, node.frame.height >= listHeight * 0.6, !kids.isEmpty {
                kids.forEach { gather($0, siblings: kids.count) }
                return
            }
            out.append(i)
        }
        let kids = tree.children[list]
        kids.forEach { gather($0, siblings: kids.count) }
        return out
    }

    mutating func rowItem(_ r: Int) -> BridgeOutline.Item? {
        let node = nodes[r]
        var parts: [BridgeOutline.Part] = []
        var scope: [String] = []
        // The row's own words come first; the row itself is what a tap on it hits.
        let own = tree.text(of: node)
        let ownValue = shownValue(node, text: own)
        for said in [own, ownValue] where !said.isEmpty && !covered(said, scope) {
            parts.append(.text(said))
            scope.append(said)
        }
        var out: [Emission] = []
        var placedTexts: [(text: String, point: BridgeOutline.Point?)] = []
        for child in tree.children[r] {
            walk(child, area: .screen, inRow: true, scope: &scope, out: &out)
        }
        for emission in out {
            switch emission {
            case .text(let t, let point):
                // The same words drawn twice in the same place (stacked views) show once.
                if let point = point, placedTexts.contains(where: { $0.text == t && $0.point == point }) { continue }
                placedTexts.append((t, point))
                parts.append(.text(t))
            case .item(let item, _): parts.append(.control(item))
            case .list: break
            }
        }
        guard !parts.isEmpty else { return nil }
        let key = "row|" + parts.map { part -> String in
            switch part {
            case .text(let t): return t
            case .control(let c): return c.text
            }
        }.joined(separator: "|")
        var states: [String] = []
        if node.disabled { states.append("disabled") }
        if node.selected { states.append("selected") }
        var row = BridgeOutline.Item(kind: .row, node: r, role: "", isControl: false, text: "", value: "", identifier: "",
                                     states: states, point: point(of: r), parts: parts, key: key)
        row.shownHeight = shownFrame(of: r)?.height ?? 0
        return row
    }

    // MARK: Helpers

    /// Left out with everything inside: scroll bars, text-selection handles
    /// and keyboard keys.
    func skipped(_ node: BridgeUITree.Node) -> Bool {
        if node.type == "Key" { return true }
        let label = tree.text(of: node).lowercased()
        if label.contains("scroll bar") || label.contains("滚动条") { return true }
        if let id = node.identifier, id.hasPrefix("com.apple.text.") || id.contains("TextSelection") { return true }
        return false
    }

    func shownValue(_ node: BridgeUITree.Node, text: String) -> String {
        let value = BridgeText.clean(node.value)
        if value == text { return "" }
        if node.type == "Switch" {
            if value == "1" { return "on" }
            if value == "0" { return "off" }
        }
        return value
    }

    func covered(_ text: String, _ scope: [String]) -> Bool {
        text.isEmpty || scope.contains { $0.contains(text) }
    }

    /// Whether a control somewhere inside node `i` says `text`: as its
    /// label, as its label and value together ("Finance" = "S$0.55" says
    /// "Finance S$0.55"), or, having no label, through the words inside it.
    func hasControl(below i: Int, saying text: String) -> Bool {
        let wanted = Self.squeezed(text)
        var stack = tree.children[i].map { ($0, 1) }
        while let (j, depth) = stack.popLast() {
            let node = nodes[j]
            if BridgeTappableHint.isControl(node) {
                let said = tree.text(of: node)
                let value = BridgeText.clean(node.value)
                let candidates = said.isEmpty ? [folded(j)] : [said, said + " " + value]
                if candidates.contains(where: { Self.squeezed($0) == wanted }) { return true }
            }
            if depth < 8 { stack += tree.children[j].map { ($0, depth + 1) } }
        }
        return false
    }

    /// Lowercased, with runs of whitespace as one space.
    static func squeezed(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whether a control saying the same, in the same place, is already listed
    /// (an app can stack two views for one button).
    static func repeats(_ item: BridgeOutline.Item, in out: [Emission]) -> Bool {
        guard item.isControl, let point = item.point else { return false }
        return out.contains {
            guard case .item(let other, _) = $0 else { return false }
            return other.isControl && other.point == point && other.text == item.text && other.value == item.value
        }
    }

    /// The words inside a node that has none of its own.
    func folded(_ i: Int) -> String {
        var words: [String] = []
        var length = 0
        var stack = Array(tree.children[i].reversed())
        while let j = stack.popLast(), length < 300 {
            let node = nodes[j]
            if skipped(node) { continue }
            let text = tree.text(of: node)
            if !text.isEmpty, !words.contains(where: { $0.contains(text) }) {
                words.append(text)
                length += text.count
            }
            stack += tree.children[j].reversed()
        }
        return words.joined(separator: " ")
    }

    /// The middle of the part of a node that shows, in screen points.
    func point(of i: Int) -> BridgeOutline.Point? {
        guard let shown = shownFrame(of: i) else { return nil }
        return BridgeOutline.Point(x: map.screenX(shown.midX).rounded(), y: map.screenY(shown.midY).rounded())
    }

    /// The part of a node that shows, in the app's points; nil when too
    /// little of it does to tap.
    func shownFrame(of i: Int) -> BridgeUITree.Rect? {
        let node = nodes[i]
        guard let area = tree.visibleArea(for: node), !area.isEmpty else { return nil }
        let shown = tree.effectiveFrame(of: node).intersection(area)
        return shown.width >= 4 && shown.height >= 4 ? shown : nil
    }

    /// Elements outside any bar or list go to the top or bottom by where they are.
    func placed(_ area: Area, _ point: BridgeOutline.Point?) -> Area {
        guard area == .screen, let p = point, screenHeight > 0 else { return area }
        if p.y < screenHeight * 0.15 { return .top }
        if p.y > screenHeight * 0.85 { return .bottom }
        return .screen
    }

    func title(of area: Area) -> String {
        switch area {
        case .alert: return "Alert"
        case .sheet: return "Sheet"
        case .top: return "Top"
        case .screen: return "Screen"
        case .toolbar: return "Toolbar"
        case .tabBar: return "Tab bar"
        case .bottom: return "Bottom"
        case .list(let i):
            let node = nodes[i]
            let name = tree.text(of: node)
            if !name.isEmpty { return "List " + BridgeText.quoted(name) }
            let id = BridgeText.clean(node.identifier)
            return id.isEmpty ? "List" : "List #\(id)"
        }
    }
}

// MARK: - Text

extension BridgeOutline {
    struct Selection {
        enum Mode {
            /// Everything on screen, then the rows nearest to it, up to the budget.
            case page
            /// Only what is on screen.
            case visible
            /// List rows by number (r40 to r90 is 40...90).
            case rows(ClosedRange<Int>)
            /// Items and rows whose text contains this.
            case filter(String)
        }
        var mode: Mode = .page
        /// Most characters of outline in one result.
        var budget = 12_000
    }

    static func describe(_ item: Item) -> String {
        var line = item.ref
        if item.kind == .row {
            let parts = item.parts.map { part -> String in
                switch part {
                case .text(let t): return BridgeText.quoted(t)
                case .control(let c): return "[" + describe(c) + "]"
                }
            }
            line += " " + parts.joined(separator: " · ")
        } else {
            if !item.role.isEmpty { line += " " + item.role }
            if !item.text.isEmpty { line += " " + BridgeText.quoted(item.text) }
            for word in item.detail { line += " · " + BridgeText.quoted(word) }
            if !item.identifier.isEmpty { line += " #" + item.identifier }
            if !item.value.isEmpty { line += " = " + BridgeText.quoted(item.value) }
        }
        for state in item.states { line += " " + state }
        if let p = item.point { line += " (\(Int(p.x)),\(Int(p.y)))" }
        return line
    }

    /// Row numbers of a list region (the n of rn), in order.
    private static func rowNumbers(_ region: Region) -> [Int] {
        region.items.compactMap { Int($0.ref.dropFirst()) }
    }

    private static func range(_ numbers: ArraySlice<Int>) -> String {
        guard let first = numbers.first, let last = numbers.last else { return "" }
        return first == last ? "r\(first)" : "r\(first)-r\(last)"
    }

    private static func listHeading(_ region: Region) -> String {
        let shown = region.items.filter { $0.point != nil }.count
        return "\(region.title) · \(region.items.count) row\(region.items.count == 1 ? "" : "s"), \(shown) on screen"
    }

    /// The outline as text, inside the limits of `selection`. Rows left out
    /// are named by range, with the call that reads them.
    func text(_ selection: Selection = Selection()) -> String {
        var lines = ["\(appName.isEmpty ? "App" : appName) · \(Int(screenWidth))x\(Int(screenHeight))"]
        if regions.isEmpty { lines.append("(nothing readable on screen)") }
        switch selection.mode {
        case .page: lines += pageLines(budget: selection.budget - lines[0].count)
        case .visible: lines += visibleLines()
        case .rows(let wanted): lines += rowLines(wanted, budget: selection.budget)
        case .filter(let needle): lines += filterLines(needle, budget: selection.budget)
        }
        if keyboardShowing { lines.append("Keyboard is showing") }
        return lines.joined(separator: "\n")
    }

    private func omitted(_ numbers: ArraySlice<Int>, _ arrow: String) -> String {
        "  \(arrow) \(numbers.count) row\(numbers.count == 1 ? "" : "s") not shown (\(Self.range(numbers))): read_ui rows:\"\(Self.range(numbers))\""
    }

    private func pageLines(budget: Int) -> [String] {
        // Everything outside lists is always shown; lists share what is left.
        var used = 0
        for region in regions where !region.isList {
            used += region.title.count + 1 + region.items.reduce(0) { $0 + Self.describe($1).count + 3 }
        }
        // Each list starts from its rows on screen. Rows can be on screen
        // apart from the rest (a sticky header, labels the app lists last
        // but draws near the top), so the list grows from the run of rows
        // on screen that covers the most of it, and the others are shown on
        // their own.
        var spans: [Int: ClosedRange<Int>] = [:]   // region index → item indices
        var shown: [Int: Set<Int>] = [:]
        var costs: [Int: [Int]] = [:]
        for (r, region) in regions.enumerated() where region.isList && !region.items.isEmpty {
            let cost = region.items.map { Self.describe($0).count + 3 }
            costs[r] = cost
            let visible = region.items.indices.filter { region.items[$0].point != nil }
            var best: ClosedRange<Int>?
            var bestCover = -1.0
            var start: Int?
            for (k, i) in visible.enumerated() {
                if start == nil || visible[k - 1] != i - 1 { start = i }
                let run = start!...i
                let cover = run.reduce(0) { $0 + region.items[$1].shownHeight }
                if cover > bestCover { best = run; bestCover = cover }
            }
            let span = best ?? 0...0
            spans[r] = span
            shown[r] = Set(visible).union(span)
            used += Self.listHeading(region).count + 1 + shown[r]!.reduce(0) { $0 + cost[$1] }
        }
        // Grow every list outwards from there, a row at a time and in turns,
        // until the budget is spent. A side stops at the first row that does
        // not fit, so the main stretch stays in one piece.
        var open: [Int: (down: Bool, up: Bool)] = spans.mapValues { _ in (true, true) }
        var grew = true
        while grew {
            grew = false
            for r in spans.keys.sorted() {
                guard var span = spans[r], var sides = open[r], let cost = costs[r] else { continue }
                func take(_ next: Int) -> Bool {
                    if shown[r]!.contains(next) { return true }
                    guard used + cost[next] <= budget else { return false }
                    used += cost[next]
                    shown[r]!.insert(next)
                    return true
                }
                if sides.down {
                    let next = span.upperBound + 1
                    if next < cost.count, take(next) { span = span.lowerBound...next; grew = true } else { sides.down = false }
                }
                if sides.up {
                    let next = span.lowerBound - 1
                    if next >= 0, take(next) { span = next...span.upperBound; grew = true } else { sides.up = false }
                }
                spans[r] = span
                open[r] = sides
            }
        }
        var lines: [String] = []
        for (r, region) in regions.enumerated() {
            if region.isList {
                if let rows = shown[r] { lines += listLines(region, showing: rows) }
            } else if !region.items.isEmpty {
                lines.append(region.title)
                lines += region.items.map { "  " + Self.describe($0) }
            }
        }
        return lines
    }

    private func visibleLines() -> [String] {
        var lines: [String] = []
        for region in regions {
            if region.isList {
                guard !region.items.isEmpty else { continue }
                lines += listLines(region, showing: Set(region.items.indices.filter { region.items[$0].point != nil }))
            } else {
                let shown = region.items.filter { $0.point != nil }
                guard !shown.isEmpty else { continue }
                lines.append(region.title)
                lines += shown.map { "  " + Self.describe($0) }
            }
        }
        return lines
    }

    /// A list's heading and the rows chosen, with every run of rows left
    /// out named, wherever it falls.
    private func listLines(_ region: Region, showing rows: Set<Int>) -> [String] {
        var lines = [Self.listHeading(region)]
        let numbers = Self.rowNumbers(region)
        var seenShown = false
        var run: [Int] = []
        func flush(_ arrow: String) {
            if let first = run.first, let last = run.last { lines.append(omitted(numbers[first...last], arrow)) }
            run = []
        }
        for (i, item) in region.items.enumerated() {
            guard rows.contains(i) else { run.append(i); continue }
            flush(seenShown ? "…" : "↑")
            seenShown = true
            lines.append("  " + Self.describe(item))
        }
        flush(seenShown ? "↓" : "·")
        return lines
    }

    private func rowLines(_ wanted: ClosedRange<Int>, budget: Int) -> [String] {
        var lines: [String] = []
        var used = 0
        for region in regions where region.isList {
            let numbers = Self.rowNumbers(region)
            let picked = region.items.indices.filter { wanted.contains(numbers[$0]) }
            guard !picked.isEmpty else { continue }
            lines.append(Self.listHeading(region))
            var cut: Int?
            for i in picked {
                let line = "  " + Self.describe(region.items[i])
                if used > 0, used + line.count > budget { cut = i; break }
                lines.append(line)
                used += line.count + 1
            }
            if let cut = cut {
                let rest = numbers[cut...picked.last!]
                lines.append(omitted(rest, "↓"))
                return lines
            }
        }
        if lines.isEmpty { lines.append("No list rows numbered \(wanted.lowerBound) to \(wanted.upperBound) on this screen.") }
        return lines
    }

    private func filterLines(_ needle: String, budget: Int) -> [String] {
        let wanted = BridgeText.clean(needle).lowercased()
        var lines: [String] = []
        var used = 0
        var left = 0
        for region in regions {
            let matches = region.items.filter { $0.searchText.lowercased().contains(wanted) }
            guard !matches.isEmpty else { continue }
            var heading: String? = region.isList ? Self.listHeading(region) : region.title
            for item in matches {
                let line = "  " + Self.describe(item)
                if used > 0, used + line.count > budget { left += 1; continue }
                if let h = heading { lines.append(h); heading = nil }
                lines.append(line)
                used += line.count + 1
            }
        }
        if lines.isEmpty { lines.append("Nothing on this screen contains that text.") }
        if left > 0 { lines.append("\(left) more match\(left == 1 ? "" : "es") not shown: use a longer filter_text.") }
        return lines
    }
}
