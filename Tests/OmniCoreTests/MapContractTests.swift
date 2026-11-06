import Foundation
import Testing
@testable import OmniCore

@Test func matrixDashMustBeDeclaredAsNone() throws {
    let data = #"{"rows":["Document"],"criteria":["Legal object"],"cells":[["—"]]}"#
    #expect(throws: OmniMapValidationError.self) { try OmniMapValidation.decode(document("matrix", data, line: "cells: facts")) }
    #expect(throws: OmniMapValidationError.self) {
        try OmniMapValidation.decode(document("matrix", data, line: "cells: — means unknown; none means absent"))
    }
    let result = try OmniMapValidation.decode(document("matrix", data, line: "cells: facts · — means none"))
    #expect(result.form == .matrix)
}

private func document(_ form: String, _ data: String, line: String, honesty: String = "leavesOut") -> String {
    """
    {"form":"\(form)","title":"Example","lineMeaning":"\(line)","honesty":{"kind":"\(honesty)","text":"A useful limit."},"data":\(data)}
    """
}

@Test func allSevenNativeFormsDecode() throws {
    let samples: [(String, String, String, String)] = [
        ("tree", #"{"rootLabel":"Book","edgeMeaning":"part of","nodes":[{"id":"a","label":"Pages","edge":"solid"}]}"#, "solid: part of", "leavesOut"),
        ("radial", #"{"hub":"Library","spokes":[{"label":"Reader"}]}"#, "spokes: association", "leavesOut"),
        ("bridge", #"{"newSide":"Git","familiarSide":"Library","pairs":[{"new":"commit","familiar":"edition"}]}"#, "arrows: plays the role of", "breaksAt"),
        ("matrix", #"{"rows":["Book"],"criteria":["Use"],"cells":[["reading"]]}"#, "cells: short facts", "leavesOut"),
        ("spectrum", #"{"axis":{"low":"Private","high":"Public"},"points":[{"label":"Diary","x":0.1}]}"#, "position on axis", "leavesOut"),
        ("loop", #"{"variables":["Trust","Use"],"links":[{"from":0,"to":1,"sign":"+"},{"from":1,"to":0,"sign":"+"}],"polarity":"R"}"#, "arrows: increases · R = reinforcing", "leavesOut"),
        ("flow", #"{"steps":["Open","Read"]}"#, "arrows: then", "leavesOut")
    ]
    for (form, data, line, honesty) in samples {
        let result = try OmniMapValidation.decode(document(form, data, line: line, honesty: honesty))
        #expect(result.form.rawValue == form)
    }
}

@Test func wrongPinnedFormFailsWithSuggestedForm() throws {
    let json = document("matrix", #"{"rows":["A"],"criteria":["Kind"],"cells":[["one"]]}"#, line: "cells: facts")
    do {
        _ = try OmniMapValidation.decode(json, pinnedForm: .tree)
        Issue.record("Expected form mismatch")
    } catch let error as OmniMapValidationError {
        #expect(error.suggestedForm == .matrix)
        #expect(error.errors.contains { $0.contains("form must be tree") })
    }
}

@Test func validatesGeometryCapsAndHonesty() throws {
    let badSpectrum = document("spectrum", #"{"axis":{"low":"A","high":"B"},"points":[{"label":"P","x":1.2}]}"#, line: "position on axis")
    #expect(throws: OmniMapValidationError.self) { try OmniMapValidation.decode(badSpectrum) }
    let noHonesty = #"{"form":"flow","title":"A","lineMeaning":"arrows: then","data":{"steps":["A","B"]}}"#
    #expect(throws: OmniMapValidationError.self) { try OmniMapValidation.decode(noHonesty) }
    let twoSentences = document("flow", #"{"steps":["A","B"]}"#, line: "arrows: then").replacingOccurrences(of: "A useful limit.", with: "One. Two.")
    #expect(throws: OmniMapValidationError.self) { try OmniMapValidation.decode(twoSentences) }
}

@Test func rejectsInvalidCycleAndInconsistentPolarity() throws {
    let data = #"{"variables":["A","B"],"links":[{"from":0,"to":1,"sign":"+"},{"from":1,"to":0,"sign":"−"}],"polarity":"R"}"#
    let json = document("loop", data, line: "arrows: increases decreases · R")
    #expect(throws: OmniMapValidationError.self) { try OmniMapValidation.decode(json) }
}

@Test func scalarOrArrayDataFailsWithoutSerializationCrash() {
    for scalar in ["null", #""text""#, "42", "[]"] {
        let json = document("flow", scalar, line: "arrows: then")
        do {
            _ = try OmniMapValidation.decode(json)
            Issue.record("Expected schema error for \(scalar)")
        } catch let error as OmniMapValidationError {
            #expect(error.errors.contains("data must be a flow object."))
        } catch {
            Issue.record("Unexpected error for \(scalar): \(error)")
        }
    }
}

@Test func loopLineMeaningNamesRealPolarityAndPresentSigns() throws {
    let allPositive = #"{"variables":["A","B"],"links":[{"from":0,"to":1,"sign":"+"},{"from":1,"to":0,"sign":"+"}],"polarity":"R"}"#
    #expect(throws: OmniMapValidationError.self) {
        try OmniMapValidation.decode(document("loop", allPositive, line: "arrows increase"))
    }
    _ = try OmniMapValidation.decode(document("loop", allPositive, line: "arrows: increases · reinforcing"))

    let allNegative = #"{"variables":["A","B"],"links":[{"from":0,"to":1,"sign":"−"},{"from":1,"to":0,"sign":"−"}],"polarity":"R"}"#
    _ = try OmniMapValidation.decode(document("loop", allNegative, line: "arrows: decreases · R"))
    #expect(throws: OmniMapValidationError.self) {
        try OmniMapValidation.decode(document("loop", allNegative, line: "arrows: increases · R"))
    }
}

@Test func formQuestionsMatchTheNativeVocabulary() {
    #expect(OmniMapForm.tree.question == "What kinds, or what parts?")
    #expect(OmniMapForm.radial.question == "What is around it, who is involved?")
    #expect(OmniMapForm.bridge.question == "How does the familiar explain the new?")
    #expect(OmniMapForm.matrix.question == "How do these differ on the same criteria?")
    #expect(OmniMapForm.spectrum.question == "Where does it sit between two poles?")
    #expect(OmniMapForm.loop.question == "What drives what, and circles back?")
    #expect(OmniMapForm.flow.question == "What happens next?")
}
