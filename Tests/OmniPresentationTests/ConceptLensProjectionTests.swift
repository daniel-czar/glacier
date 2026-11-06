import Foundation
import OmniPresentation
import Testing

private func conceptJSON(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return try #require(String(data: data, encoding: .utf8))
}

@Test func conceptLensProjectsMapAndCondensedCopy() throws {
    let response = try conceptJSON([
        "name": "Construct validity", "field": "Psychometrics",
        "definition": "A measure captures the construct it claims to measure.",
        "parents": ["Validity"],
        "siblings": ["Content validity", "Criterion validity", "Face validity"],
        "children": ["Convergent validity"], "related": ["Reliability"],
        "nearMisses": [["name": "Reliability", "distinction": "consistency, not target accuracy"]]
    ])
    let projection = OmniConceptLensProjection.project(response, input: "test meaning")
    let map = try #require(projection.map)
    #expect(projection.failureReason == nil)
    #expect(map.name == "Construct validity")
    #expect(map.field == "Psychometrics")
    #expect(map.definition == "A measure captures the construct it claims to measure.")
    #expect(map.siblings == ["Content validity", "Criterion validity", "Face validity"])
    #expect(map.nearMisses == [.init(name: "Reliability", distinction: "consistency, not target accuracy")])
    #expect(projection.text == """
        Name: Construct validity
        Field: Psychometrics
        Definition: A measure captures the construct it claims to measure.
        Parents: Validity
        Siblings: Content validity, Criterion validity
        Children: Convergent validity
        Near misses:
        Reliability — consistency, not target accuracy
        Related: Reliability
        """)
    #expect(!projection.text.contains("Match signal"))
    #expect(!projection.text.contains("Often confused"))
}

@Test func conceptLensDropsBadFieldsAndEntriesIndependentlyThenClampsCaps() throws {
    let response = try conceptJSON([
        "name": 99, "field": ["wrong type"],
        "definition": "Too long. Another sentence.",
        "parents": ["Ancestor one", 1, "four words are invalid", "Ancestor two", "Ancestor three", "Ancestor four"],
        "siblings": ["One", "Two", "Three", "Four", "Five"],
        "children": ["A", "B", "C", "D", "E", "F"],
        "related": ["R1", "R2", "R3", "R4", "R5", "R6"],
        "nearMisses": [
            ["name": "Bad distinction", "distinction": 4],
            ["name": "Miss one", "distinction": "different mechanism"],
            ["name": "Miss two", "distinction": "different scope"],
            ["name": "Miss three", "distinction": "different evidence"],
            ["name": "Miss four", "distinction": "different target"],
            ["name": "Miss five", "distinction": "different use"]
        ]
    ])
    let projection = OmniConceptLensProjection.project(response, input: "Seed concept")
    let map = try #require(projection.map)
    #expect(map.name == "Seed concept")
    #expect(map.field == nil)
    #expect(map.definition == nil)
    #expect(map.parents == ["Ancestor one", "Ancestor two", "Ancestor three"])
    #expect(map.siblings == ["One", "Two", "Three", "Four"])
    #expect(map.children == ["A", "B", "C", "D", "E"])
    #expect(map.related == ["R1", "R2", "R3", "R4", "R5"])
    #expect(map.nearMisses.map(\.name) == ["Miss one", "Miss two", "Miss three", "Miss four"])
    #expect(projection.text.contains("Siblings: One, Two"))
    #expect(!projection.text.contains("Siblings: One, Two, Three"))
    #expect(projection.failureReason == nil)
}

@Test func conceptLensKeepsUsefulMapWithOverlongNameAndDefinition() throws {
    let longDefinition = Array(repeating: "word", count: 26).joined(separator: " ") + "."
    let response = try conceptJSON([
        "name": "A name with four words", "definition": longDefinition,
        "field": "  decision   theory  ",
        "nearMisses": [
            ["name": "Four word near miss", "distinction": "different scope"],
            ["name": "Valid miss", "distinction": "one two three four five six seven eight nine ten eleven twelve"],
            ["name": "Good miss", "distinction": "different cause"]
        ]
    ])
    let projection = OmniConceptLensProjection.project(response, input: "A long input phrase that cannot be used")
    let map = try #require(projection.map)
    #expect(map.name == "Concept")
    #expect(map.field == "decision theory")
    #expect(map.definition == nil)
    #expect(map.nearMisses == [.init(name: "Good miss", distinction: "different cause")])
}

@Test func conceptLensAcceptsWordLimitsAndIgnoresWrongListType() throws {
    let exactDefinition = Array(repeating: "word", count: 25).joined(separator: " ") + "."
    let response = try conceptJSON([
        "name": "Three Word Name", "definition": exactDefinition,
        "parents": "not a list", "siblings": ["Three Word Peer"],
        "nearMisses": [["name": "Three Word Miss", "distinction": "one two three four five six"]]
    ])
    let projection = OmniConceptLensProjection.project(response, input: "input")
    let map = try #require(projection.map)
    #expect(map.name == "Three Word Name")
    #expect(map.definition == exactDefinition)
    #expect(map.parents.isEmpty)
    #expect(map.siblings == ["Three Word Peer"])
    #expect(map.nearMisses == [.init(name: "Three Word Miss", distinction: "one two three four five six")])
    #expect(projection.text == OmniConceptLensProjection.projectedText(map))
}

@Test func conceptLensUsesSafeFallbackForUnusableJSON() throws {
    let noFields = try conceptJSON(["name": 7, "parents": [7], "definition": false])
    let unusable = OmniConceptLensProjection.project(noFields, input: "Input term")
    #expect(unusable.map == nil)
    #expect(unusable.failureReason?.contains("no usable map fields") == true)
    #expect(unusable.text == noFields)

    let malformed = OmniConceptLensProjection.project("{\"name\":", input: "too many input words here")
    #expect(malformed.map == nil)
    #expect(malformed.failureReason?.contains("invalid JSON") == true)
    #expect(malformed.text == "{\"name\":")

    let empty = OmniConceptLensProjection.project("  ", input: "Anchor")
    #expect(empty.map == nil)
    #expect(!empty.text.isEmpty)
    #expect(empty.failureReason != nil)
}

@Test func conceptLensKeepsAValidNameWhenEveryOtherFieldFails() {
    let projection = OmniConceptLensProjection.project(#"{"name":"Diagnosis","field":false,"definition":12,"parents":"invalid"}"#, input: "input")
    #expect(projection.map?.name == "Diagnosis")
    #expect(projection.map?.definition == nil)
    #expect(projection.failureReason == nil)
    #expect(projection.text == "Name: Diagnosis")
}

@Test func conceptLensRetainsReceivedPlainTextAndAcceptsFencedJSON() throws {
    let legacy = "PRIMARY\n- Name: Construct validity\nNEAR MISSES\n- Reliability: consistency, not truth"
    let plain = OmniConceptLensProjection.project(legacy, input: "construct validity")
    #expect(plain.map == nil)
    #expect(plain.text == legacy)
    #expect(plain.failureReason?.contains("plain text") == true)

    let json = try conceptJSON(["name": "Frame", "children": ["Subframe"]])
    let fenced = OmniConceptLensProjection.project("```json\n\(json)\n```", input: "frame")
    #expect(fenced.map?.name == "Frame")
    #expect(fenced.map?.children == ["Subframe"])
}
