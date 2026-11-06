import Foundation

public enum OmniMapForm: String, CaseIterable, Codable, Sendable {
    case tree, radial, bridge, matrix, spectrum, loop, flow

    public var title: String { rawValue.capitalized }

    public var question: String {
        switch self {
        case .tree: "What kinds, or what parts?"
        case .radial: "What is around it, who is involved?"
        case .bridge: "How does the familiar explain the new?"
        case .matrix: "How do these differ on the same criteria?"
        case .spectrum: "Where does it sit between two poles?"
        case .loop: "What drives what, and circles back?"
        case .flow: "What happens next?"
        }
    }
}

public struct OmniMapHonesty: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case leavesOut, breaksAt }
    public let kind: Kind
    public let text: String
    public init(kind: Kind, text: String) { self.kind = kind; self.text = text }
}

public struct OmniMapTree: Codable, Sendable, Equatable {
    public enum EdgeMeaning: String, Codable, Sendable { case kindOf = "kind of", partOf = "part of", supports }
    public enum Edge: String, Codable, Sendable { case solid, dashed }
    public struct Node: Codable, Sendable, Equatable {
        public let id: String
        public let label: String
        public let parent: String?
        public let edge: Edge?
        public init(id: String, label: String, parent: String? = nil, edge: Edge? = nil) {
            self.id = id; self.label = label; self.parent = parent; self.edge = edge
        }
    }
    public let rootLabel: String
    public let edgeMeaning: EdgeMeaning
    public let nodes: [Node]
    public init(rootLabel: String, edgeMeaning: EdgeMeaning, nodes: [Node]) {
        self.rootLabel = rootLabel; self.edgeMeaning = edgeMeaning; self.nodes = nodes
    }
}

public struct OmniMapRadial: Codable, Sendable, Equatable {
    public struct Spoke: Codable, Sendable, Equatable {
        public let label: String
        public let edgeLabel: String?
        public let children: [String]
        public let offered: Bool
        public init(label: String, edgeLabel: String? = nil, children: [String] = [], offered: Bool = false) {
            self.label = label; self.edgeLabel = edgeLabel; self.children = children; self.offered = offered
        }
        private enum CodingKeys: String, CodingKey { case label, edgeLabel, children, offered }
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            label = try container.decode(String.self, forKey: .label)
            edgeLabel = try container.decodeIfPresent(String.self, forKey: .edgeLabel)
            children = try container.decodeIfPresent([String].self, forKey: .children) ?? []
            offered = try container.decodeIfPresent(Bool.self, forKey: .offered) ?? false
        }
    }
    public let hub: String
    public let spokes: [Spoke]
    public init(hub: String, spokes: [Spoke]) { self.hub = hub; self.spokes = spokes }
}

public struct OmniMapBridge: Codable, Sendable, Equatable {
    public struct Pair: Codable, Sendable, Equatable {
        public let new: String
        public let familiar: String
        public init(new: String, familiar: String) { self.new = new; self.familiar = familiar }
    }
    public let newSide: String
    public let familiarSide: String
    public let pairs: [Pair]
    public init(newSide: String, familiarSide: String, pairs: [Pair]) {
        self.newSide = newSide; self.familiarSide = familiarSide; self.pairs = pairs
    }
}

public struct OmniMapMatrix: Codable, Sendable, Equatable {
    public let rows: [String]
    public let criteria: [String]
    public let cells: [[String]]
    public let offered: [Int]
    public init(rows: [String], criteria: [String], cells: [[String]], offered: [Int] = []) {
        self.rows = rows; self.criteria = criteria; self.cells = cells; self.offered = offered
    }
    private enum CodingKeys: String, CodingKey { case rows, criteria, cells, offered }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rows = try container.decode([String].self, forKey: .rows)
        criteria = try container.decode([String].self, forKey: .criteria)
        cells = try container.decode([[String]].self, forKey: .cells)
        offered = try container.decodeIfPresent([Int].self, forKey: .offered) ?? []
    }
}

public struct OmniMapSpectrum: Codable, Sendable, Equatable {
    public struct Axis: Codable, Sendable, Equatable {
        public let low: String
        public let high: String
        public init(low: String, high: String) { self.low = low; self.high = high }
    }
    public struct Point: Codable, Sendable, Equatable {
        public let label: String
        public let x: Double
        public let y: Double?
        public init(label: String, x: Double, y: Double? = nil) { self.label = label; self.x = x; self.y = y }
    }
    public let axis: Axis
    public let axis2: Axis?
    public let points: [Point]
    public init(axis: Axis, axis2: Axis? = nil, points: [Point]) {
        self.axis = axis; self.axis2 = axis2; self.points = points
    }
}

public struct OmniMapLoop: Codable, Sendable, Equatable {
    public enum Sign: String, Codable, Sendable { case positive = "+", negative = "−" }
    public enum Polarity: String, Codable, Sendable { case reinforcing = "R", balancing = "B" }
    public struct Link: Codable, Sendable, Equatable {
        public let from: Int
        public let to: Int
        public let sign: Sign
        public init(from: Int, to: Int, sign: Sign) { self.from = from; self.to = to; self.sign = sign }
    }
    public let variables: [String]
    public let links: [Link]
    public let polarity: Polarity
    public init(variables: [String], links: [Link], polarity: Polarity) {
        self.variables = variables; self.links = links; self.polarity = polarity
    }
}

public struct OmniMapFlow: Codable, Sendable, Equatable {
    public struct Branch: Codable, Sendable, Equatable {
        public let at: Int
        public let label: String
        public let steps: [String]
        public init(at: Int, label: String, steps: [String]) { self.at = at; self.label = label; self.steps = steps }
    }
    public let steps: [String]
    public let branch: Branch?
    public init(steps: [String], branch: Branch? = nil) { self.steps = steps; self.branch = branch }
}

public enum OmniMapData: Sendable, Equatable {
    case tree(OmniMapTree)
    case radial(OmniMapRadial)
    case bridge(OmniMapBridge)
    case matrix(OmniMapMatrix)
    case spectrum(OmniMapSpectrum)
    case loop(OmniMapLoop)
    case flow(OmniMapFlow)

    public var form: OmniMapForm {
        switch self {
        case .tree: .tree
        case .radial: .radial
        case .bridge: .bridge
        case .matrix: .matrix
        case .spectrum: .spectrum
        case .loop: .loop
        case .flow: .flow
        }
    }
}

public struct OmniMapDocument: Sendable, Equatable {
    public let form: OmniMapForm
    public let title: String
    public let lineMeaning: String
    public let honesty: OmniMapHonesty
    public let data: OmniMapData
    public init(form: OmniMapForm, title: String, lineMeaning: String, honesty: OmniMapHonesty, data: OmniMapData) {
        self.form = form; self.title = title; self.lineMeaning = lineMeaning; self.honesty = honesty; self.data = data
    }
}

public struct OmniMapValidationError: Error, Sendable, Equatable, LocalizedError {
    public let errors: [String]
    public let suggestedForm: OmniMapForm?
    public init(_ errors: [String], suggestedForm: OmniMapForm? = nil) {
        self.errors = errors; self.suggestedForm = suggestedForm
    }
    public var errorDescription: String? { "Map could not be drawn. Edit the question and try again." }
}

public enum OmniMapValidation {
    public static func decode(_ response: String, pinnedForm: OmniMapForm? = nil, candidateForms: [OmniMapForm] = []) throws -> OmniMapDocument {
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: Data(response.utf8)) }
        catch { throw OmniMapValidationError(["Response must be one JSON object."]) }
        guard let object = json as? [String: Any] else { throw OmniMapValidationError(["Response must be one JSON object."]) }
        guard let formName = object["form"] as? String, let form = OmniMapForm(rawValue: formName) else {
            throw OmniMapValidationError(["form must be a native map form."])
        }
        var errors: [String] = []
        if let pinnedForm, form != pinnedForm { errors.append("form must be \(pinnedForm.rawValue).") }
        if !candidateForms.isEmpty && !candidateForms.contains(form) { errors.append("form must be one of \(candidateForms.map(\.rawValue).joined(separator: ", ")).") }
        let title = requiredString(object, "title", errors: &errors)
        let lineMeaning = requiredString(object, "lineMeaning", errors: &errors)
        if wordCount(lineMeaning) > 8 { errors.append("lineMeaning must have at most 8 words.") }
        var honesty: OmniMapHonesty?
        if let raw = object["honesty"] as? [String: Any] {
            let kindName = requiredString(raw, "kind", errors: &errors)
            let text = requiredString(raw, "text", errors: &errors)
            if let kind = OmniMapHonesty.Kind(rawValue: kindName) { honesty = .init(kind: kind, text: text) }
            else { errors.append("honesty.kind must be leavesOut or breaksAt.") }
            if !text.isEmpty && !isOneSentence(text) { errors.append("honesty.text must be one sentence ending in punctuation.") }
        } else { errors.append("honesty is required.") }
        if let honesty, honesty.kind != (form == .bridge ? .breaksAt : .leavesOut) {
            errors.append("honesty.kind must be \(form == .bridge ? "breaksAt" : "leavesOut") for \(form.rawValue).")
        }
        guard let rawData = object["data"] else { errors.append("data is required."); throw OmniMapValidationError(errors, suggestedForm: form) }
        guard let dataObject = rawData as? [String: Any] else {
            errors.append("data must be a \(form.rawValue) object.")
            throw OmniMapValidationError(errors, suggestedForm: form)
        }
        let data: OmniMapData?
        do {
            let bytes = try JSONSerialization.data(withJSONObject: dataObject)
            let decoder = JSONDecoder()
            switch form {
            case .tree: data = .tree(try decoder.decode(OmniMapTree.self, from: bytes))
            case .radial: data = .radial(try decoder.decode(OmniMapRadial.self, from: bytes))
            case .bridge: data = .bridge(try decoder.decode(OmniMapBridge.self, from: bytes))
            case .matrix: data = .matrix(try decoder.decode(OmniMapMatrix.self, from: bytes))
            case .spectrum: data = .spectrum(try decoder.decode(OmniMapSpectrum.self, from: bytes))
            case .loop: data = .loop(try decoder.decode(OmniMapLoop.self, from: bytes))
            case .flow: data = .flow(try decoder.decode(OmniMapFlow.self, from: bytes))
            }
        } catch {
            errors.append("data does not match the \(form.rawValue) schema: \(error.localizedDescription)")
            data = nil
        }
        if let data { validate(data, lineMeaning: lineMeaning, errors: &errors) }
        guard errors.isEmpty, let honesty, let data else { throw OmniMapValidationError(errors, suggestedForm: form) }
        return OmniMapDocument(form: form, title: title, lineMeaning: lineMeaning, honesty: honesty, data: data)
    }

    private static func requiredString(_ object: [String: Any], _ key: String, errors: inout [String]) -> String {
        guard let raw = object[key] as? String else { errors.append("\(key) is required and must be text."); return "" }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { errors.append("\(key) cannot be empty.") }
        return value
    }

    private static func wordCount(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    private static func isOneSentence(_ text: String) -> Bool {
        let end = text.last
        guard end == "." || end == "!" || end == "?" else { return false }
        let body = text.dropLast()
        return !body.contains(where: { $0 == "." || $0 == "!" || $0 == "?" })
    }

    private static func validate(_ data: OmniMapData, lineMeaning: String, errors: inout [String]) {
        func label(_ text: String, _ path: String, maxWords: Int? = nil) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("\(path) cannot be empty.") }
            if let maxWords, wordCount(text) > maxWords { errors.append("\(path) exceeds \(maxWords) words.") }
        }
        switch data {
        case .tree(let tree):
            label(tree.rootLabel, "rootLabel")
            if tree.nodes.count > 11 { errors.append("tree has more than 12 nodes including rootLabel.") }
            if tree.nodes.isEmpty { errors.append("tree needs nodes.") }
            let ids = tree.nodes.map(\.id)
            if Set(ids).count != ids.count { errors.append("tree node ids must be unique.") }
            let nodesByID = Dictionary(tree.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for node in tree.nodes {
                label(node.id, "node.id"); label(node.label, "node.label", maxWords: 3)
                if let parent = node.parent, nodesByID[parent] == nil { errors.append("tree parent \(parent) is missing.") }
                if node.parent == node.id { errors.append("tree node cannot parent itself.") }
            }
            for node in tree.nodes {
                var seen: Set<String> = [node.id]
                var current = node
                var depth = 2 // rootLabel is the first level.
                while let parent = current.parent, let next = nodesByID[parent] {
                    if !seen.insert(parent).inserted { errors.append("tree has a cycle."); break }
                    depth += 1; current = next
                }
                if depth > 3 { errors.append("tree exceeds 3 levels."); break }
            }
            if !lineMeaning.lowercased().contains(tree.edgeMeaning.rawValue) { errors.append("lineMeaning must declare the tree solid-edge meaning.") }
            if tree.nodes.contains(where: { $0.edge == .dashed }) && !lineMeaning.lowercased().contains("objects to") { errors.append("lineMeaning must declare dashed edges as objects to.") }
        case .radial(let radial):
            label(radial.hub, "hub")
            if radial.spokes.isEmpty || radial.spokes.count > 8 { errors.append("radial needs 1–8 spokes.") }
            for spoke in radial.spokes {
                label(spoke.label, "spoke.label")
                if let edgeLabel = spoke.edgeLabel { label(edgeLabel, "spoke.edgeLabel", maxWords: 1) }
                if spoke.children.count > 2 { errors.append("radial spoke exceeds 2 children.") }
                for child in spoke.children { label(child, "spoke.child") }
            }
            if !lineMeaning.lowercased().contains("spoke") { errors.append("lineMeaning must declare spoke meaning.") }
        case .bridge(let bridge):
            label(bridge.newSide, "newSide"); label(bridge.familiarSide, "familiarSide")
            if bridge.pairs.isEmpty || bridge.pairs.count > 5 { errors.append("bridge needs 1–5 pairs.") }
            for pair in bridge.pairs { label(pair.new, "pair.new"); label(pair.familiar, "pair.familiar") }
            if !lineMeaning.lowercased().contains("role") { errors.append("lineMeaning must declare the role analogy.") }
        case .matrix(let matrix):
            if matrix.rows.isEmpty || matrix.rows.count > 5 { errors.append("matrix needs 1–5 rows.") }
            if matrix.criteria.isEmpty || matrix.criteria.count > 4 { errors.append("matrix needs 1–4 criteria.") }
            if matrix.cells.count != matrix.rows.count || matrix.cells.contains(where: { $0.count != matrix.criteria.count }) { errors.append("matrix cells must match row and criterion dimensions.") }
            for row in matrix.rows { label(row, "row") }
            for criterion in matrix.criteria { label(criterion, "criterion") }
            for cell in matrix.cells.flatMap({ $0 }) { label(cell, "cell", maxWords: 3) }
            if Set(matrix.offered).count != matrix.offered.count || matrix.offered.contains(where: { $0 < 0 || $0 >= matrix.rows.count }) { errors.append("offered row indices must be unique and in range.") }
            if !lineMeaning.lowercased().contains("cell") { errors.append("lineMeaning must declare cell meaning.") }
            if matrix.cells.contains(where: { $0.contains("—") }),
               lineMeaning.range(of: #"—\s*(?:means|=|:)\s*none\b"#, options: [.regularExpression, .caseInsensitive]) == nil {
                errors.append("lineMeaning must declare that — means none.")
            }
        case .spectrum(let spectrum):
            label(spectrum.axis.low, "axis.low"); label(spectrum.axis.high, "axis.high")
            if let axis2 = spectrum.axis2 { label(axis2.low, "axis2.low"); label(axis2.high, "axis2.high") }
            if spectrum.points.isEmpty || spectrum.points.count > 7 { errors.append("spectrum needs 1–7 points.") }
            for point in spectrum.points {
                label(point.label, "point.label")
                if !point.x.isFinite || point.x < 0 || point.x > 1 { errors.append("point.x must be finite and between 0 and 1.") }
                if let y = point.y, (!y.isFinite || y < 0 || y > 1) { errors.append("point.y must be finite and between 0 and 1.") }
                if spectrum.axis2 == nil && point.y != nil { errors.append("point.y needs axis2.") }
                if spectrum.axis2 != nil && point.y == nil { errors.append("axis2 needs every point.y.") }
            }
            if !lineMeaning.lowercased().contains("position") { errors.append("lineMeaning must declare position meaning.") }
        case .loop(let loop):
            if loop.variables.count < 2 || loop.variables.count > 6 { errors.append("loop needs 2–6 variables.") }
            for variable in loop.variables { label(variable, "variable", maxWords: 3) }
            if loop.links.count != loop.variables.count { errors.append("loop needs one link per variable, making one cycle.") }
            var outgoing = Array(repeating: 0, count: loop.variables.count)
            var incoming = outgoing
            for link in loop.links {
                if link.from < 0 || link.from >= loop.variables.count || link.to < 0 || link.to >= loop.variables.count { errors.append("loop link indices must be in range."); continue }
                outgoing[link.from] += 1; incoming[link.to] += 1
            }
            if outgoing.contains(where: { $0 != 1 }) || incoming.contains(where: { $0 != 1 }) { errors.append("loop links must make one directed cycle.") }
            if loop.links.count == loop.variables.count, !loop.variables.isEmpty {
                var seen: Set<Int> = [0]; var cursor = 0
                for _ in 0..<loop.variables.count {
                    guard let next = loop.links.first(where: { $0.from == cursor })?.to else { break }
                    cursor = next; seen.insert(cursor)
                }
                if seen.count != loop.variables.count || cursor != 0 { errors.append("loop links must be connected in one cycle.") }
            }
            let negative = loop.links.filter { $0.sign == .negative }.count
            let expected: OmniMapLoop.Polarity = negative.isMultiple(of: 2) ? .reinforcing : .balancing
            if loop.polarity != expected { errors.append("loop polarity disagrees with link signs.") }
            let meaning = lineMeaning.lowercased()
            let positive = loop.links.count - negative
            let words = Set(meaning.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            let hasPolarity = loop.polarity == .reinforcing
                ? words.contains("r") || words.contains("reinforcing")
                : words.contains("b") || words.contains("balancing")
            if (positive > 0 && !meaning.contains("increase"))
                || (negative > 0 && !meaning.contains("decrease"))
                || !hasPolarity {
                errors.append("lineMeaning must explain present signed arrows and loop polarity.")
            }
        case .flow(let flow):
            if flow.steps.isEmpty || flow.steps.count > 7 { errors.append("flow needs 1–7 steps.") }
            for step in flow.steps { label(step, "step") }
            if let branch = flow.branch {
                if branch.at < 0 || branch.at >= flow.steps.count { errors.append("flow branch index must name a main step.") }
                label(branch.label, "branch.label")
                if branch.steps.isEmpty || flow.steps.count + branch.steps.count > 7 { errors.append("flow branch needs steps and total steps must be at most 7.") }
                for step in branch.steps { label(step, "branch.step") }
            }
            if !lineMeaning.lowercased().contains("then") { errors.append("lineMeaning must declare arrows as then.") }
        }
    }
}
