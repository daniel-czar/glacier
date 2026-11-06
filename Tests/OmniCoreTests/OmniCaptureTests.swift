import OmniCore
import Testing

@Test func captureClassifiesOnlyAWholeValidWebURLAsALink() {
    #expect(OmniCaptureRequest.classify("https://example.com/path?q=1") ==
            OmniCaptureRequest.classify(" https://example.com/path?q=1 \n"))
    #expect(OmniCaptureRequest.classify("www.example.com/a")?.payload == "https://www.example.com/a")
    #expect(OmniCaptureRequest.classify("http://localhost:8080/a")?.destination == .link)
    for input in ["see https://example.com", "https://example.com and more", "https://", "ftp://example.com", "www.", "https://example.com/a b"] {
        #expect(OmniCaptureRequest.classify(input)?.destination == .note)
        #expect(OmniCaptureRequest.classify(input)?.payload == input)
    }
}

@Test func capturePreservesNoteWhitespaceAndDoesNotClassifyBlankInput() {
    let note = "  Remember /todo and @project\nSecond line  "
    #expect(OmniCaptureRequest.classify(note)?.payload == note)
    #expect(OmniCaptureRequest.classify(note)?.destination == .note)
    #expect(OmniCaptureRequest.classify(" \n\t") == nil)
}
