import Foundation

/// Small, allocation-conscious helpers for looking at copied text.
public enum TextAnalysis {
    /// The form text is matched in: lowercased, without diacritics or width differences, so
    /// that "resume" finds "Résumé". The Turkish dotless ı has no decomposition and is
    /// folded by hand, so that "isik" finds "IŞIK" and "ışık" alike.
    public static func folded(_ string: some StringProtocol) -> String {
        string
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "ı", with: "i")
    }

    /// The terms a search for `query` has to match, folded. At most eight are used.
    public static func searchTerms(in query: String) -> [String] {
        query
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .prefix(8)
            .map { folded($0) }
            .filter { !$0.isEmpty }
    }

    /// The beginning of `text` tidied up for a card: blank lines at either end are dropped
    /// and indentation shared by every line is removed, so indented code starts at the left
    /// edge instead of floating in the middle.
    public static func preview(of text: String, limit: Int = 800) -> String {
        // Only the start is ever shown. Do not walk megabytes of text to find it.
        let window = text.prefix(limit * 4)
        var lines = window.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let isBlank: (Substring) -> Bool = { $0.allSatisfy(\.isWhitespace) }
        while let first = lines.first, isBlank(first) { lines.removeFirst() }
        while let last = lines.last, isBlank(last) { lines.removeLast() }
        guard !lines.isEmpty else { return "" }

        let indent = lines
            .filter { !isBlank($0) }
            .map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }
            .min() ?? 0
        let joined = lines
            .map { line -> Substring in isBlank(line) ? "" : line.dropFirst(indent) }
            .joined(separator: "\n")
        return String(joined.prefix(limit))
    }

    public struct Counts: Sendable, Equatable {
        public var characters: Int
        public var words: Int
        public var lines: Int
    }

    /// Characters, words and lines in one pass.
    public static func counts(of text: String) -> Counts {
        var characters = 0
        var words = 0
        var lines = text.isEmpty ? 0 : 1
        var inWord = false
        for character in text {
            characters += 1
            if character.isNewline {
                lines += 1
                inWord = false
            } else if character.isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
            }
        }
        if let last = text.last, last.isNewline { lines -= 1 }
        return Counts(characters: characters, words: words, lines: max(lines, text.isEmpty ? 0 : 1))
    }

    /// Apps whose copies are almost always code or commands.
    static let codeApps: Set<String> = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed", "com.sublimetext.4", "com.sublimetext.3", "com.panic.Nova", "org.vim.MacVim",
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "dev.warp.Warp-Stable", "co.zeit.hyper", "com.github.wez.wezterm", "org.alacritty",
    ]

    /// Whether clips copied from `bundleID` should be treated as code without looking.
    public static func isCodeApp(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return codeApps.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.")
    }

    private static let codeSymbols: Set<Character> = ["{", "}", "[", "]", "(", ")", ";", "=", "<", ">", "|", "&", "$", "#", "\\", "_", "`"]

    private static let codeMarkers = [
        "func ", "let ", "var ", "const ", "def ", "class ", "struct ", "import ", "return ", "#include", "public ",
        "private ", "static ", "=> ", "->", "fn ", "SELECT ", "INSERT ", "FROM ", "</", "/>", "if (", "for (",
        "while (", "::", "!=", "==", "&&", "||", "+=", "//", "/*", "#!/",
    ]

    /// A cheap guess at whether `text` is source code, a config file or a shell command
    /// rather than prose. It looks at the start of the text only.
    public static func looksLikeCode(_ text: String) -> Bool {
        let sample = text.prefix(3000)
        guard sample.count >= 8 else { return false }
        var score = 0.0

        let symbols = sample.reduce(0) { $0 + (codeSymbols.contains($1) ? 1 : 0) }
        let density = Double(symbols) / Double(sample.count)
        if density > 0.035 { score += 1 }
        if density > 0.08 { score += 1 }

        let lines = sample.split(whereSeparator: \.isNewline)
        if lines.count >= 3 {
            let indented = lines.reduce(0) { $0 + (($1.hasPrefix("  ") || $1.hasPrefix("\t")) ? 1 : 0) }
            if Double(indented) / Double(lines.count) > 0.3 { score += 1 }
            let terminated = lines.reduce(0) { count, line in
                guard let last = line.last(where: { !$0.isWhitespace }) else { return count }
                return count + ((last == ";" || last == "{" || last == "}") ? 1 : 0)
            }
            if Double(terminated) / Double(lines.count) > 0.25 { score += 1 }
        }

        let markers = codeMarkers.reduce(0) { $0 + (sample.contains($1) ? 1 : 0) }
        score += min(Double(markers) * 0.5, 2)

        let trimmed = sample.drop(while: { $0.isWhitespace || $0.isNewline })
        if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) && sample.contains("\":") { score += 2 }
        if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<!DOCTYPE") || trimmed.hasPrefix("<html") { score += 2 }

        return score >= 2
    }
}
