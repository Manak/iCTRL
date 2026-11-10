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

    /// Rewrites every frame in a `page_source` text into screen points.
    func rescale(_ source: String) -> String {
        guard !isIdentity else { return source }
        let regex = try! NSRegularExpression(pattern: #"\{\{(-?[0-9.]+), (-?[0-9.]+)\}, \{(-?[0-9.]+), (-?[0-9.]+)\}\}"#)
        let ns = source as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let v = (1...4).map { Double(ns.substring(with: match.range(at: $0))) ?? 0 }
            let x = Int(screenX(v[0]).rounded()), y = Int(screenY(v[1]).rounded())
            let w = Int(screenWidth(v[2]).rounded()), h = Int(screenHeight(v[3]).rounded())
            out += "{{\(x), \(y)}, {\(w), \(h)}}"
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
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
