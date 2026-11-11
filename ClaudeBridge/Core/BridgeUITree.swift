import Foundation

/// A parsed copy of iCTRL's `page_source` text, so the bridge can find an
/// element, work out where it really is, and bring it into view itself.
///
/// Two things about real apps make this necessary (both seen in Grab on
/// iOS 27):
/// - an app can draw in its own coordinate space (375 x 667) scaled onto a
///   larger screen, so its frames are not tap points until converted;
/// - children of an off-screen row can all report the same bogus frame (the
///   list's origin), which makes "is it on screen?" wrong unless the row's
///   own frame is used instead.
struct BridgeUITree {
    struct Rect: Equatable {
        var x, y, width, height: Double
        var midX: Double { x + width / 2 }
        var midY: Double { y + height / 2 }
        var maxX: Double { x + width }
        var maxY: Double { y + height }
        var isEmpty: Bool { width <= 0 || height <= 0 }

        func contains(x px: Double, y py: Double) -> Bool {
            px >= x && px <= maxX && py >= y && py <= maxY
        }
        func intersection(_ other: Rect) -> Rect {
            let nx = max(x, other.x), ny = max(y, other.y)
            return Rect(x: nx, y: ny, width: max(0, min(maxX, other.maxX) - nx), height: max(0, min(maxY, other.maxY) - ny))
        }
    }

    struct Node {
        let index: Int
        let depth: Int
        let type: String
        let label: String?
        let value: String?
        let identifier: String?
        let frame: Rect
        var parent: Int?
        /// The app has greyed this element out.
        var disabled = false
        var selected = false
    }

    private(set) var nodes: [Node] = []
    /// Each node's children, by index, in order.
    private(set) var children: [[Int]] = []

    private static let frameRegex = try! NSRegularExpression(
        pattern: #"\{\{(-?[0-9.]+), (-?[0-9.]+)\}, \{(-?[0-9.]+), (-?[0-9.]+)\}\}$"#)

    /// Parses the device's text in one pass. Lines that are not elements
    /// (anything without a frame at the end) are skipped.
    init(source: String) {
        var stack: [(depth: Int, index: Int)] = []
        for line in BridgeSourceLines.join(source).components(separatedBy: "\n") {
            guard let parsed = Self.parse(line) else { continue }
            while let last = stack.last, last.depth >= parsed.indent { stack.removeLast() }
            var node = Node(index: nodes.count, depth: parsed.indent, type: parsed.type,
                            label: parsed.label, value: parsed.value, identifier: parsed.identifier,
                            frame: parsed.frame, parent: stack.last?.index)
            node.disabled = parsed.disabled
            node.selected = parsed.selected
            nodes.append(node)
            children.append([])
            if let parent = node.parent { children[parent].append(node.index) }
            stack.append((parsed.indent, node.index))
        }
    }

    struct ParsedLine: Equatable {
        var indent: Int
        var type: String
        var label: String?
        var value: String?
        var identifier: String?
        var disabled = false
        var selected = false
        var frame: Rect
    }

    /// One element line:
    ///
    ///     <indent>Type[, label: '…'][, value: '…'][, id: '…'][, disabled][, selected], {{x, y}, {w, h}}
    ///
    /// Read from both ends: the frame is last and the state words come just
    /// before it, so neither is looked for inside the text. A label ends only
    /// where the next field begins (`', value: '` or `', id: '`) or at the
    /// final quote, so commas and quotes inside it do not cut it short.
    static func parse(_ line: String) -> ParsedLine? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = frameRegex.firstMatch(in: line, range: range),
              let frameRange = Range(match.range, in: line) else { return nil }
        func number(_ i: Int) -> Double {
            Range(match.range(at: i), in: line).flatMap { Double(line[$0]) } ?? 0
        }
        let frame = Rect(x: number(1), y: number(2), width: number(3), height: number(4))
        let indent = line.prefix { $0 == " " }.count
        var head = Substring(line[line.index(line.startIndex, offsetBy: indent)..<frameRange.lowerBound])
        guard head.hasSuffix(", ") else { return nil }
        head = head.dropLast(2)

        let type = head.prefix { $0 != "," }
        guard !type.isEmpty, type.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        var parsed = ParsedLine(indent: indent, type: String(type), frame: frame)
        var rest = head.dropFirst(type.count)

        // State words, from the end. Inside a field they would be followed
        // by its closing quote, so they cannot be mistaken here.
        while let word = [", disabled", ", selected", ", tappable"].first(where: { rest.hasSuffix($0) }) {
            rest = rest.dropLast(word.count)
            if word == ", disabled" { parsed.disabled = true }
            if word == ", selected" { parsed.selected = true }
        }

        // Fields, in their fixed order.
        let fields: [(key: String, next: [String])] = [
            ("label", ["', value: '", "', id: '"]), ("value", ["', id: '"]), ("id", []),
        ]
        for (key, next) in fields {
            let opener = ", \(key): '"
            guard rest.hasPrefix(opener) else { continue }
            let body = rest.dropFirst(opener.count)
            var end: Substring.Index?
            for terminator in next {
                if let r = body.range(of: terminator), r.lowerBound < (end ?? body.endIndex) { end = r.lowerBound }
            }
            let text: Substring
            if let end = end {
                text = body[..<end]
                rest = body[body.index(after: end)...]   // keep the ", next: '" part
            } else {
                text = body.hasSuffix("'") ? body.dropLast() : body
                rest = ""
            }
            switch key {
            case "label": parsed.label = String(text)
            case "value": parsed.value = String(text)
            default: parsed.identifier = String(text)
            }
        }
        // Anything left over is a field this parser does not know; the
        // element is still kept with what was read.
        return parsed
    }

    /// A node's label as shown: without invisible direction marks, and empty
    /// when it only repeats the element's type ("Toolbar", "Tab Bar").
    func text(of node: Node) -> String {
        let label = BridgeText.clean(node.label)
        let squeezed = label.replacingOccurrences(of: " ", with: "")
        return squeezed.caseInsensitiveCompare(node.type) == .orderedSame ? "" : label
    }

    /// The app's own drawing area: the frame of the root node.
    var appFrame: Rect? { nodes.first?.frame }

    // MARK: Finding

    enum Match { case exact, contains }

    /// Nodes whose label or identifier matches, best candidates first:
    /// label matches before identifier matches, in document order. Invisible
    /// direction marks are ignored on both sides, since read_ui leaves them out.
    func find(_ text: String, match: Match) -> [Node] {
        let wanted = BridgeText.clean(text).lowercased()
        guard !wanted.isEmpty else { return [] }
        func hit(_ candidate: String?) -> Bool {
            let c = BridgeText.clean(candidate).lowercased()
            guard !c.isEmpty else { return false }
            return match == .exact ? c == wanted : c.contains(wanted)
        }
        let byLabel = nodes.filter { hit($0.label) }
        let byID = nodes.filter { !hit($0.label) && hit($0.identifier) }
        return byLabel + byID
    }

    /// How the device can find the same node: by its label as the app has it
    /// (else its identifier), and which match it is in document order. The
    /// device compares label and identifier alike, ignoring case. nil when
    /// the node has neither.
    func deviceQuery(for node: Node) -> (text: String, occurrence: Int)? {
        let key = (node.label?.isEmpty == false ? node.label : node.identifier) ?? ""
        guard !key.isEmpty else { return nil }
        let lower = key.lowercased()
        // The device searches the app's descendants, so the app itself does not count.
        let before = nodes[1..<max(1, node.index)].filter {
            $0.label?.lowercased() == lower || $0.identifier?.lowercased() == lower
        }.count
        return (BridgeSourceLines.deviceText(key), before + 1)
    }

    private func ancestor(of node: Node, where test: (Node) -> Bool) -> Node? {
        var current = node.parent
        while let i = current {
            if test(nodes[i]) { return nodes[i] }
            current = nodes[i].parent
        }
        return nil
    }

    static let scrollTypes: Set<String> = ["Table", "CollectionView", "ScrollView", "WebView"]

    /// The nearest enclosing element that probably responds to a tap.
    func tappableAncestor(of node: Node) -> Node? {
        ancestor(of: node) { BridgeTappableHint.isLikelyTappable($0) }
    }

    /// The scrolling view a node lives in, if any.
    func scrollContainer(of node: Node) -> Node? {
        ancestor(of: node) { Self.scrollTypes.contains($0.type) }
    }

    /// Where the node really is. A node's own frame is trusted only if it
    /// lies inside its row, top to bottom; otherwise the row's frame is
    /// used, because children of off-screen rows can report a bogus frame
    /// (the list's origin). Only the height is checked: a row that scrolls
    /// sideways really does have children beyond its edges.
    func effectiveFrame(of node: Node) -> Rect {
        guard let row = row(of: node), row.index != node.index else { return node.frame }
        if !node.frame.isEmpty, node.frame.midY >= row.frame.y, node.frame.midY <= row.frame.maxY {
            return node.frame
        }
        return row.frame
    }

    /// The row a node belongs to: the nearest cell, or else the nearest
    /// element placed directly in a list.
    func row(of node: Node) -> Node? {
        var current: Node? = node
        var placed: Node?
        while let n = current {
            if n.type == "Cell" { return n }
            if placed == nil, let p = n.parent, Self.scrollTypes.contains(nodes[p].type) { placed = n }
            current = n.parent.map { nodes[$0] }
        }
        return placed
    }

    /// The part of the screen in which a node's scrolling view shows content.
    func visibleArea(for node: Node) -> Rect? {
        guard let app = appFrame else { return nil }
        guard let container = scrollContainer(of: node) else { return app }
        return container.frame.intersection(app)
    }

    /// Whether the node's centre is showing inside its scrolling view.
    func isInView(_ node: Node, margin: Double = 6) -> Bool {
        guard let area = visibleArea(for: node), !area.isEmpty else { return false }
        let frame = effectiveFrame(of: node)
        return frame.midY >= area.y + margin && frame.midY <= area.maxY - margin
            && frame.midX >= area.x && frame.midX <= area.maxX
    }
}

/// Marks the elements that probably respond to a tap.
///
/// iOS has no "clickable" flag. An element's type says a lot (a Button is
/// tappable), but many real controls are plain views whose only clue is their
/// identifier. So this is a hint, not a fact: it will miss custom controls
/// and can flag something inert.
enum BridgeTappableHint {
    static let types: Set<String> = [
        "Button", "Link", "Cell", "Switch", "TextField", "SecureTextField", "SearchField", "TextView",
        "Slider", "SegmentedControl", "Key", "Icon", "PickerWheel",
    ]
    /// Words that mark a control when they appear as a part of an identifier.
    static let identifierWords: Set<String> = ["button", "btn", "tab", "cta", "link", "toggle", "checkbox", "radiobutton", "chip"]

    static func isLikelyTappable(_ node: BridgeUITree.Node) -> Bool {
        !node.disabled && isControl(node)
    }

    /// A control, whether it can be used right now or is greyed out.
    static func isControl(_ node: BridgeUITree.Node) -> Bool {
        guard !node.frame.isEmpty else { return false }
        if types.contains(node.type) { return true }
        guard let id = node.identifier?.lowercased() else { return false }
        let parts = id.split(whereSeparator: { !$0.isLetter })
        return parts.contains { identifierWords.contains(String($0)) }
    }
}

/// Converts between an app's own coordinate space and screen points.
///
/// Most apps fill the screen and need no conversion. An app shown in a window,
/// or scaled to fit, reports frames in its own space; where that space sits on
/// screen is measured by the runner (`appWindow`) rather than assumed.
struct BridgeCoordinateMap: Equatable {
    let scaleX: Double
    let scaleY: Double
    let offsetX: Double
    let offsetY: Double

    static let identity = BridgeCoordinateMap(scaleX: 1, scaleY: 1, offsetX: 0, offsetY: 0)

    init(scaleX: Double, scaleY: Double, offsetX: Double, offsetY: Double) {
        self.scaleX = scaleX; self.scaleY = scaleY; self.offsetX = offsetX; self.offsetY = offsetY
    }

    /// From the app's own frame and the rectangle it occupies on screen.
    init(appFrame: BridgeUITree.Rect, window: BridgeUITree.Rect) {
        guard !appFrame.isEmpty, !window.isEmpty else { self = .identity; return }
        let sx = window.width / appFrame.width, sy = window.height / appFrame.height
        let map = BridgeCoordinateMap(scaleX: sx, scaleY: sy,
                                      offsetX: window.x - appFrame.x * sx, offsetY: window.y - appFrame.y * sy)
        self = map.isNearIdentity ? .identity : map
    }

    /// Fallback when the window was not measured: scaled to fit, top-left.
    init(appWidth: Double, appHeight: Double, screenWidth: Double, screenHeight: Double) {
        guard appWidth > 0, appHeight > 0, screenWidth > 0, screenHeight > 0 else { self = .identity; return }
        let s = min(screenWidth / appWidth, screenHeight / appHeight)
        self = abs(s - 1) < 0.005 ? .identity : BridgeCoordinateMap(scaleX: s, scaleY: s, offsetX: 0, offsetY: 0)
    }

    private var isNearIdentity: Bool {
        abs(scaleX - 1) < 0.005 && abs(scaleY - 1) < 0.005 && abs(offsetX) < 1 && abs(offsetY) < 1
    }

    var isIdentity: Bool { self == .identity }

    func screenX(_ x: Double) -> Double { x * scaleX + offsetX }
    func screenY(_ y: Double) -> Double { y * scaleY + offsetY }
    /// A length along x or y (no offset).
    func screenWidth(_ w: Double) -> Double { w * scaleX }
    func screenHeight(_ h: Double) -> Double { h * scaleY }
}

/// What the runner found on screen by asking iOS which process owns the
/// pixels at several points.
struct BridgeScreenInspection {
    /// Bundle id of the app that owns the screen, or nil when that cannot be
    /// vouched for (an unknown process is showing somewhere).
    var foregroundBundle: String?
    /// The rectangle that app occupies, in screen points, when measured.
    var appWindow: BridgeUITree.Rect?
}

/// Decides which app is in front from what iOS reports about processes.
///
/// "Frontmost process" alone is not enough. On iOS 27 an app can be shown in a
/// window, and then the frontmost process is the system's window host (the
/// same process as the pull-down search), not the app. An app's own "running
/// in the foreground" state can also lag by seconds after it leaves the
/// screen, so it is never trusted by itself when a process id can settle it.
enum BridgeForegroundDecision {
    /// - Parameters:
    ///   - frontPID: the process iOS calls frontmost.
    ///   - springboardPID: SpringBoard's process.
    ///   - searchPID: the system search / window host process.
    ///   - searchActive: that process reports itself as the foreground app.
    ///   - foregroundApps: every known app that reports itself in the
    ///     foreground, bundle id to process id (allowlisted or not).
    /// - Returns: the bundle id in front, or nil when it cannot be vouched for.
    static func decide(frontPID: Int32, springboardPID: Int32, searchPID: Int32, searchActive: Bool,
                       foregroundApps: [String: Int32], springboard: String, search: String) -> String? {
        guard frontPID > 0 else { return nil }
        if frontPID == springboardPID { return springboard }
        // A full-screen app: the frontmost process is the app itself.
        if let app = foregroundApps.first(where: { $0.value == frontPID }) { return app.key }
        guard searchPID > 0, frontPID == searchPID else { return nil }
        if searchActive { return search }
        // The window host is in front without being the search screen. With
        // no app claiming the foreground this is the host's own screen (on a
        // large display it is the home screen: icons and a search bar), which
        // is treated like search. With one claim, that app is shown in a
        // window. Two claims means one of them is stale, so neither is named.
        switch foregroundApps.count {
        case 0: return search
        case 1: return foregroundApps.first!.key
        default: return nil
        }
    }
}

/// Finds where a windowed app sits on screen, from SpringBoard's UI tree.
///
/// When an app is shown in a window, SpringBoard lays the stage out in the
/// display's logical size (669 x 951 on the phone this was written for) while
/// taps use the runner's size (466 x 678). The app's window appears in
/// SpringBoard's tree as an element with exactly the app's own size.
enum BridgeWindowLocator {
    static func locate(appFrame: BridgeUITree.Rect, springboard: BridgeUITree) -> BridgeUITree.Rect? {
        guard let screen = springboard.appFrame, !screen.isEmpty, !appFrame.isEmpty else { return nil }
        // The stage's logical size: the commonest window size that is not the screen size.
        var counts: [String: (rect: BridgeUITree.Rect, n: Int)] = [:]
        for node in springboard.nodes where node.type == "Window" && node.frame.x == 0 && node.frame.y == 0 {
            let f = node.frame
            guard abs(f.width - screen.width) > 1, f.width > screen.width, f.width < screen.width * 2.5 else { continue }
            let key = "\(Int(f.width))x\(Int(f.height))"
            counts[key] = (f, (counts[key]?.n ?? 0) + 1)
        }
        guard let logical = counts.values.max(by: { $0.n < $1.n })?.rect else { return nil }
        let scale = screen.width / logical.width

        // The app's window: an element of exactly the app's size, inside the stage.
        guard let window = springboard.nodes.first(where: {
            abs($0.frame.width - appFrame.width) <= 1 && abs($0.frame.height - appFrame.height) <= 1
                && $0.frame.maxX <= logical.width + 1 && $0.frame.maxY <= logical.height + 1
        })?.frame else { return nil }
        return BridgeUITree.Rect(x: window.x * scale, y: window.y * scale,
                                 width: window.width * scale, height: window.height * scale)
    }
}

/// Puts every element of a `page_source` text back on one line.
///
/// The device writes one element per line, but a label or value is written
/// as it is, so a message with line breaks in it (a WhatsApp bubble, say)
/// spills over several lines. Every reader here goes line by line: the
/// spilled lines were taken for elements of their own and each piece was cut
/// at its first comma. Here the pieces are joined again, with each line break
/// written as `\n`.
///
/// A complete element line always ends with its frame, `{{x, y}, {w, h}}`.
/// So a line that starts an element and opens a label, value or identifier
/// but has no frame is joined with the lines after it, up to the first one
/// that ends with a frame.
enum BridgeSourceLines {
    /// How a line break inside a label is shown.
    static let lineBreak = "\\n"

    private static let elementStart = try! NSRegularExpression(
        pattern: #"^ *[A-Za-z][A-Za-z0-9]*, (label|value|id): '"#)
    private static let frameAtEnd = try! NSRegularExpression(
        pattern: #"\{\{-?[0-9.]+, -?[0-9.]+\}, \{-?[0-9.]+, -?[0-9.]+\}\}$"#)

    static func join(_ source: String) -> String {
        guard source.contains("\n") else { return source }
        let lines = source.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var pending: [String] = []
        var changed = false
        for line in lines {
            if !pending.isEmpty {
                pending.append(line)
                if endsWithFrame(line) {
                    out.append(pending.map(trimReturn).joined(separator: lineBreak))
                    pending.removeAll()
                    changed = true
                }
                continue
            }
            if !endsWithFrame(line), matches(elementStart, line) {
                pending = [line]
            } else {
                out.append(line)
            }
        }
        // A spill that never reached a frame was not one: leave it as it was.
        out.append(contentsOf: pending)
        return changed ? out.joined(separator: "\n") : source
    }

    /// Text as the device has it, from text written the way read_ui shows it.
    static func deviceText(_ shown: String) -> String {
        shown.replacingOccurrences(of: lineBreak, with: "\n")
    }

    private static func endsWithFrame(_ line: String) -> Bool {
        line.contains("}}") && matches(frameAtEnd, line)
    }

    private static func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
        regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func trimReturn(_ piece: String) -> String {
        piece.hasSuffix("\r") ? String(piece.dropLast()) : piece
    }
}

extension BridgeRawAPI {
    /// `page_source`, with each element on a line of its own.
    func pageSource(_ params: BridgeJSON) -> BridgeRawResult {
        let result = call("page_source", params)
        guard case .success(var page) = result, let source = page["source"] as? String else { return result }
        page["source"] = BridgeSourceLines.join(source)
        return .success(page)
    }
}
