import Foundation

/// Recognizes copied text that is a single URL and nothing else.
public enum LinkDetector {
    private static let webSchemes: Set<String> = ["http", "https", "ftp", "ftps", "sftp", "ssh", "ws", "wss"]

    public static func url(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 4096,
              !trimmed.contains(where: { $0.isWhitespace || $0.isNewline })
        else { return nil }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            if webSchemes.contains(scheme) {
                return (url.host() ?? "").isEmpty ? nil : url
            }
            if scheme == "mailto" {
                return trimmed.contains("@") ? url : nil
            }
            // App links such as notion://… or obsidian://open?vault=…. Requiring "://"
            // keeps "localhost:3000" and "key:value" as plain text.
            if trimmed.contains("://"), trimmed.count > scheme.count + 3 {
                return url
            }
            return nil
        }

        // "www.example.com/page", copied without a scheme.
        if trimmed.lowercased().hasPrefix("www."), let url = URL(string: "https://" + trimmed),
           let host = url.host(), host.dropFirst(4).contains(".") {
            return url
        }
        return nil
    }
}
