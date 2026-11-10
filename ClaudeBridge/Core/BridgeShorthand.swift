import Foundation

/// Rewrites the tree text read_ui returns into a shorter notation.
///
/// Only the words the bridge and the device write themselves are shortened:
/// element types, field names, state words, frames and repeated identifiers.
/// Labels and values, the text that is actually on the screen, are passed
/// through untouched. On a long Grab menu the system text was over 80% of
/// the characters, most of it frames and identifiers repeated on every row.
///
/// One line reads:
///
///     <indent>TYPE 'label' ='value' #identifier flags frame
///
/// This is output only. Everything the bridge does itself (finding,
/// scrolling, tapping) keeps working from the device's own text.
enum BridgeShorthand {
    /// One or two letters for the types that make up nearly every line. The
    /// rest are rare enough to spell out.
    static let typeCodes: [String: String] = [
        "StaticText": "T", "Button": "B", "Image": "I", "Cell": "C", "Other": "O",
        "Link": "L", "TextField": "F", "Switch": "S",
    ]
    static let typeLegend = "T text, B button, I image, C cell, O other, L link, F text field, S switch; other types are spelled out"

    /// Leaf types that say nothing when they carry no text and no identifier.
    static let emptyLeafTypes: Set<String> = ["StaticText", "Image"]

    /// An identifier used at least this often is written once in the ids
    /// line and referred to by number.
    static let minimumRepeats = 3

    struct Output {
        /// One line per element kept, in order.
        var lines: [String] = []
        /// Parallel to `lines`: the numbered identifier the line refers to.
        var references: [Int?] = []
        /// Numbered identifiers, by number - 1.
        var identifiers: [String] = []
        /// Empty elements left out.
        var dropped = 0

        /// The `ids:` line for a range of lines: only the numbers used there.
        func identifierLine(for range: Range<Int>) -> String? {
            let used = Set(references[range].compactMap { $0 }).sorted()
            guard !used.isEmpty else { return nil }
            return "ids: " + used.map { "$\($0)=\(identifiers[$0 - 1])" }.joined(separator: " ")
        }
    }

    /// `source` is tree text with frames already in screen points.
    static func encode(_ source: String, screenWidth: Double, screenHeight: Double) -> Output {
        let tree = BridgeUITree(source: source)
        let nodes = tree.nodes
        let screen = BridgeUITree.Rect(x: 0, y: 0, width: screenWidth, height: screenHeight)

        var hasChild = [Bool](repeating: false, count: nodes.count)
        for node in nodes { if let parent = node.parent { hasChild[parent] = true } }
        let tappable = nodes.map { BridgeTappableHint.isLikelyTappable($0) }

        func isEmptyLeaf(_ node: BridgeUITree.Node) -> Bool {
            emptyLeafTypes.contains(node.type) && !hasChild[node.index]
                && (node.label ?? "").isEmpty && (node.value ?? "").isEmpty && (node.identifier ?? "").isEmpty
                && !node.selected && !node.disabled && !tappable[node.index]
        }
        func onScreen(_ frame: BridgeUITree.Rect) -> Bool {
            if frame.isEmpty { return screen.contains(x: frame.x, y: frame.y) }
            return !frame.intersection(screen).isEmpty
        }

        // Number the identifiers that repeat, in order of first use.
        var uses: [String: Int] = [:]
        for node in nodes where !isEmptyLeaf(node) {
            if let id = node.identifier, !id.isEmpty { uses[id, default: 0] += 1 }
        }
        var numberOf: [String: Int] = [:]
        var output = Output()

        // Depth among the lines kept, one space each.
        var depth = [Int](repeating: 0, count: nodes.count)
        var index = 0
        for line in source.components(separatedBy: "\n") {
            guard line.range(of: ", {{", options: .backwards) != nil, line.hasSuffix("}}"), index < nodes.count else {
                if !line.isEmpty { output.lines.append(line); output.references.append(nil) }
                continue
            }
            let node = nodes[index]
            index += 1
            depth[node.index] = node.parent.map { depth[$0] + 1 } ?? 0
            if isEmptyLeaf(node) { output.dropped += 1; continue }

            var text = String(repeating: " ", count: depth[node.index]) + (typeCodes[node.type] ?? node.type)
            if let label = node.label, !label.isEmpty { text += " '\(label)'" }
            if let value = node.value, !value.isEmpty { text += " ='\(value)'" }
            var reference: Int?
            if let id = node.identifier, !id.isEmpty {
                if uses[id, default: 0] >= minimumRepeats {
                    if numberOf[id] == nil {
                        output.identifiers.append(id)
                        numberOf[id] = output.identifiers.count
                    }
                    reference = numberOf[id]
                    text += " $\(reference!)"
                } else {
                    text += " #\(id)"
                }
            }
            if tappable[node.index] { text += " *" }
            if node.disabled { text += " dis" }
            if node.selected { text += " sel" }

            let frame = node.frame
            func whole(_ value: Double) -> String { String(Int(value.rounded())) }
            if onScreen(frame) {
                text += " \(whole(frame.x)),\(whole(frame.y)),\(whole(frame.width)),\(whole(frame.height))"
            } else {
                // Off screen the exact frame is no use for tapping, and
                // inside an off-screen row it is often just the row's origin.
                let parent = node.parent.map { nodes[$0] }
                let withParent = parent.map { !onScreen($0.frame) && ($0.frame.x == frame.x && $0.frame.y == frame.y || frame.isEmpty) } ?? false
                if !withParent { text += " ~\(whole(frame.midX)),\(whole(frame.midY))" }
            }
            output.lines.append(text)
            output.references.append(reference)
        }
        return output
    }
}
