import OmniCore
import Testing

@Test func clipboardRoutesKeepTheirLiteralSearchTail() {
    #expect(OmniClipboardRoute.query(in: "/cl") == "")
    #expect(OmniClipboardRoute.query(in: "  /clipboard  a /literal query  ") == "a /literal query")
    #expect(OmniClipboardRoute.query(in: "/cl\t  two words") == "two words")
    #expect(OmniClipboardRoute.query(in: "/clover") == nil)
    #expect(OmniClipboardRoute.query(in: "/Clipboard") == nil)
    #expect(OmniClipboardRoute.query(in: "/email /cl") == nil)
}
