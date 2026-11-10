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
    }

    private(set) var nodes: [Node] = []

    private static let frameRegex = try! NSRegularExpression(
        pattern: #"\{\{(-?[0-9.]+), (-?[0-9.]+)\}, \{(-?[0-9.]+), (-?[0-9.]+)\}\}\s*$"#)

    init(source: String) {
        var stack: [(depth: Int, index: Int)] = []
        for line in source.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = Self.frameRegex.firstMatch(in: line, range: range) else { continue }
            func number(_ i: Int) -> Double {
                Range(match.range(at: i), in: line).flatMap { Double(line[$0]) } ?? 0
            }
            let frame = Rect(x: number(1), y: number(2), width: number(3), height: number(4))
            let indent = line.prefix { $0 == " " }.count
            let head = String(line[line.index(line.startIndex, offsetBy: indent)..<Range(match.range, in: line)!.lowerBound])
            let type = head.split(separator: ",", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""

            while let last = stack.last, last.depth >= indent { stack.removeLast() }
            let node = Node(index: nodes.count, depth: indent, type: type,
                            label: Self.field("label", in: head), value: Self.field("value", in: head),
                            identifier: Self.field("id", in: head), frame: frame, parent: stack.last?.index)
            nodes.append(node)
            stack.append((indent, node.index))
        }
    }

    /// Reads `name: '…'` from a tree line. Values may contain commas and
    /// quotes, so the end is the quote that precedes the next field or the frame.
    private static func field(_ name: String, in head: String) -> String? {
        guard let start = head.range(of: ", \(name): '") else { return nil }
        let rest = head[start.upperBound...]
        var end = rest.endIndex
        for terminator in ["', label: '", "', value: '", "', id: '", "', "] {
            if let r = rest.range(of: terminator), r.lowerBound < end { end = r.lowerBound }
        }
        if end == rest.endIndex, rest.hasSuffix("'") { end = rest.index(before: rest.endIndex) }
        return String(rest[..<end])
    }

    /// The app's own drawing area: the frame of the root node.
    var appFrame: Rect? { nodes.first?.frame }

    // MARK: Finding

    enum Match { case exact, contains }

    /// Nodes whose label or identifier matches, best candidates first:
    /// label matches before identifier matches, in document order.
    func find(_ text: String, match: Match) -> [Node] {
        let wanted = text.lowercased()
        func hit(_ candidate: String?) -> Bool {
            guard let c = candidate?.lowercased(), !c.isEmpty else { return false }
            return match == .exact ? c == wanted : c.contains(wanted)
        }
        let byLabel = nodes.filter { hit($0.label) }
        let byID = nodes.filter { !hit($0.label) && hit($0.identifier) }
        return byLabel + byID
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

    /// The scrolling view a node lives in, if any.
    func scrollContainer(of node: Node) -> Node? {
        ancestor(of: node) { Self.scrollTypes.contains($0.type) }
    }

    /// Where the node really is. A node's own frame is trusted only if it
    /// lies inside its row; otherwise the row's frame is used, because
    /// children of off-screen rows can report a bogus frame.
    func effectiveFrame(of node: Node) -> Rect {
        guard let cell = node.type == "Cell" ? node : ancestor(of: node, where: { $0.type == "Cell" }) else {
            return node.frame
        }
        if !node.frame.isEmpty, cell.frame.contains(x: node.frame.midX, y: node.frame.midY) {
            return node.frame
        }
        return cell.frame
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

/// Converts between an app's own coordinate space and screen points.
///
/// An app that draws in a smaller space is scaled uniformly and placed at the
/// top-left of the screen (as observed on iOS 27).
struct BridgeCoordinateMap: Equatable {
    let scale: Double

    static let identity = BridgeCoordinateMap(scale: 1)

    init(scale: Double) { self.scale = scale }

    init(appWidth: Double, appHeight: Double, screenWidth: Double, screenHeight: Double) {
        guard appWidth > 0, appHeight > 0, screenWidth > 0, screenHeight > 0 else { self.scale = 1; return }
        let s = min(screenWidth / appWidth, screenHeight / appHeight)
        // Ignore rounding noise; only a real difference counts.
        self.scale = abs(s - 1) < 0.005 ? 1 : s
    }

    var isIdentity: Bool { scale == 1 }

    func toScreen(_ value: Double) -> Double { value * scale }

    /// Rewrites every frame in a `page_source` text into screen points.
    func rescale(_ source: String) -> String {
        guard !isIdentity else { return source }
        let regex = try! NSRegularExpression(pattern: #"\{\{(-?[0-9.]+), (-?[0-9.]+)\}, \{(-?[0-9.]+), (-?[0-9.]+)\}\}"#)
        let ns = source as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let v = (1...4).map { Int(((Double(ns.substring(with: match.range(at: $0))) ?? 0) * scale).rounded()) }
            out += "{{\(v[0]), \(v[1])}, {\(v[2]), \(v[3])}}"
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}
