import Foundation
import Testing

@testable import OpenClipboardKit

@Suite struct ColorParserTests {
    @Test(arguments: [
        ("#FF8800", "#FF8800"),
        ("#ff8800", "#FF8800"),
        ("#0af", "#00AAFF"),
        ("#000", "#000000"),
        ("#FF880080", "#FF880080"),
        ("#FF8800FF", "#FF8800"),
        ("rgb(255, 136, 0)", "#FF8800"),
        ("rgb(255 136 0)", "#FF8800"),
        ("rgba(255, 136, 0, 0.5)", "#FF880080"),
        ("rgb(255 136 0 / 50%)", "#FF880080"),
        ("rgb(100%, 0%, 0%)", "#FF0000"),
        ("hsl(0, 100%, 50%)", "#FF0000"),
        ("hsl(120deg 100% 25%)", "#008000"),
        ("hsla(240, 100%, 50%, 0.5)", "#0000FF80"),
        ("  #FF8800\n", "#FF8800"),
    ])
    func parses(_ input: String, _ hex: String) {
        #expect(ColorParser.parse(input)?.hex == hex)
    }

    @Test(arguments: [
        "#123", "#1234", "#12", "#GGGGGG", "FF8800", "rgb(300, 0, 0)", "rgb(1, 2)", "hsl(0, 100, 50)",
        "color: #FF8800", "#FF8800 is orange", "rgb", "", "translate(10, 20, 30)",
    ])
    func rejects(_ input: String) {
        #expect(ColorParser.parse(input) == nil)
    }

    @Test func describesColors() {
        let orange = RGBAColor(red: 1, green: 136.0 / 255, blue: 0)
        #expect(orange.rgbDescription == "rgb(255, 136, 0)")
        #expect(orange.hslDescription == "hsl(32, 100%, 50%)")
        #expect(RGBAColor(red: 0, green: 0, blue: 1, alpha: 0.5).rgbDescription == "rgba(0, 0, 255, 0.5)")
        #expect(RGBAColor(red: 1, green: 1, blue: 1).luminance > 0.99)
        #expect(RGBAColor(red: 0, green: 0, blue: 0).luminance < 0.01)
    }
}

@Suite struct TextOnColorTests {
    /// The accent colors of macOS and its system colors, light and dark.
    @Test(arguments: ["#007AFF", "#0A84FF", "#953D96", "#BF5AF2", "#F74F9E", "#FF375F", "#E0383E", "#FF453A", "#8C8C8C"])
    func whiteTextOnTheDarkerColors(_ hex: String) {
        #expect(ColorParser.parse(hex)?.needsDarkText == false)
    }

    @Test(arguments: ["#F7821B", "#FF9500", "#FF9F0A", "#FFC600", "#FFD60A", "#62BA46", "#34C759", "#30D158", "#FF990A"])
    func darkTextOnTheLightOnes(_ hex: String) {
        #expect(ColorParser.parse(hex)?.needsDarkText == true)
    }
}

@Suite struct PageToneTests {
    private func color(_ hex: String) -> RGBAColor { ColorParser.parse(hex)! }

    @Test func darkTextGetsAWhitePage() {
        #expect(PageTone.suiting([(color("#000000"), 100)]) == .light)
        #expect(PageTone.suiting([(color("#333333"), 80), (color("#0066CC"), 20)]) == .light)
        #expect(PageTone.suiting([(color("#CC0000"), 10)]) == .light)
    }

    @Test func lightTextGetsADarkPage() {
        // What Telegram copies in dark mode: white, which a white page swallows.
        #expect(PageTone.suiting([(color("#FFFFFF"), 13)]) == .dark)
        // A dark editor theme: no color is near white, and all of them need a dark page.
        #expect(PageTone.suiting([(color("#D4D4D4"), 40), (color("#569CD6"), 20), (color("#CE9178"), 20), (color("#6A9955"), 20)]) == .dark)
    }

    @Test func theMajorityDecides() {
        #expect(PageTone.suiting([(color("#111111"), 200), (color("#FFD60A"), 6)]) == .light)
        #expect(PageTone.suiting([(color("#F2F2F7"), 200), (color("#0A84FF"), 12)]) == .dark)
        #expect(PageTone.suiting([]) == .light)
    }
}

@Suite struct TextAnalysisTests {
    @Test func foldsForSearching() {
        #expect(TextAnalysis.folded("Crème BRÛLÉE") == "creme brulee")
        #expect(TextAnalysis.folded("IŞIK ışık İstanbul") == "isik isik istanbul")
        #expect(TextAnalysis.folded("ＦＵＬＬ ｗｉｄｔｈ") == "full width")
        #expect(TextAnalysis.searchTerms(in: "  Two   Términos ") == ["two", "terminos"])
        #expect(TextAnalysis.searchTerms(in: " ").isEmpty)
    }

    @Test func previewsDropBlankEdgesAndSharedIndentation() {
        let text = "\n\n        if ready {\n            go()\n        }\n\n"
        #expect(TextAnalysis.preview(of: text) == "if ready {\n    go()\n}")
        #expect(TextAnalysis.preview(of: "   \n \n") == "")
        #expect(TextAnalysis.preview(of: "one\n\ntwo") == "one\n\ntwo")
        #expect(TextAnalysis.preview(of: String(repeating: "a", count: 5000), limit: 100).count == 100)
    }

    @Test func counts() {
        #expect(TextAnalysis.counts(of: "") == .init(characters: 0, words: 0, lines: 0))
        #expect(TextAnalysis.counts(of: "one") == .init(characters: 3, words: 1, lines: 1))
        #expect(TextAnalysis.counts(of: "one two\nthree\n") == .init(characters: 14, words: 3, lines: 2))
        #expect(TextAnalysis.counts(of: "a\r\nb") == .init(characters: 3, words: 2, lines: 2))
        #expect(TextAnalysis.counts(of: "👨‍👩‍👧 family") == .init(characters: 8, words: 2, lines: 1))
    }
}
