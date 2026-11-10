import Foundation

/// A color in sRGB, components from 0 to 1.
public struct RGBAColor: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when the color is not opaque.
    public var hex: String {
        let channel: (Double) -> Int = { Int(($0 * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", channel(red), channel(green), channel(blue))
        return alpha >= 0.999 ? rgb : rgb + String(format: "%02X", channel(alpha))
    }

    /// Perceived brightness, 0 (black) to 1 (white). Decides whether text on top of the
    /// color should be dark or light.
    public var luminance: Double {
        let linear: (Double) -> Double = { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public var rgbDescription: String {
        let channel: (Double) -> Int = { Int(($0 * 255).rounded()) }
        if alpha >= 0.999 {
            return "rgb(\(channel(red)), \(channel(green)), \(channel(blue)))"
        }
        return "rgba(\(channel(red)), \(channel(green)), \(channel(blue)), \(Self.trimmed(alpha)))"
    }

    public var hslDescription: String {
        let maximum = max(red, green, blue), minimum = min(red, green, blue)
        let lightness = (maximum + minimum) / 2
        var hue = 0.0, saturation = 0.0
        let delta = maximum - minimum
        if delta > 0.00001 {
            saturation = delta / (1 - abs(2 * lightness - 1))
            switch maximum {
            case red: hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            case green: hue = (blue - red) / delta + 2
            default: hue = (red - green) / delta + 4
            }
            hue *= 60
            if hue < 0 { hue += 360 }
        }
        let body = "\(Int(hue.rounded())), \(Int((saturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%"
        return alpha >= 0.999 ? "hsl(\(body))" : "hsla(\(body), \(Self.trimmed(alpha)))"
    }

    private static func trimmed(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// The background that formatted text should be shown on, judged by its own colors.
public enum PageTone: Sendable, Equatable {
    /// A white page: the text is dark, as it is when copied from a document or a web page.
    case light
    /// A dark page: the text is light, as it is when copied from an app in dark mode.
    case dark

    /// The luminance of the dark page, a near black.
    static let darkPageLuminance = 0.012

    /// Chooses the page on which text in the given colors is easier to read. Each color
    /// counts for as many characters as are drawn in it.
    ///
    /// The measure is the contrast ratio of the Web Content Accessibility Guidelines,
    /// summed over the text for a white page and for a dark one. Text of any color with a
    /// luminance above about 0.2 reads better on dark, which is why a threshold of one
    /// half would be wrong: the blues and oranges of a dark editor theme are well below it.
    public static func suiting(_ colors: [(color: RGBAColor, characters: Int)]) -> PageTone {
        var onWhite = 0.0, onDark = 0.0
        for (color, characters) in colors {
            let luminance = color.luminance
            onWhite += Double(characters) * (1.05 / (luminance + 0.05))
            onDark += Double(characters) * ((luminance + 0.05) / (darkPageLuminance + 0.05))
        }
        return onDark > onWhite ? .dark : .light
    }
}

/// Recognizes copied text that is nothing but a CSS color: `#1E90FF`, `#fff`, `rgb(30 144 255)`,
/// `rgba(30, 144, 255, 0.5)`, `hsl(210, 100%, 56%)`.
public enum ColorParser {
    public static func parse(_ string: String) -> RGBAColor? {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 4, text.count <= 48 else { return nil }
        if text.hasPrefix("#") { return hex(text.dropFirst()) }
        let lowered = text.lowercased()
        guard lowered.hasSuffix(")"), let open = lowered.firstIndex(of: "(") else { return nil }
        let name = lowered[..<open]
        let arguments = lowered[lowered.index(after: open)..<lowered.index(before: lowered.endIndex)]
            .split(whereSeparator: { $0 == "," || $0 == "/" || $0.isWhitespace })
            .map(String.init)
        switch name {
        case "rgb", "rgba": return rgb(arguments)
        case "hsl", "hsla": return hsl(arguments)
        default: return nil
        }
    }

    private static func hex(_ digits: Substring) -> RGBAColor? {
        guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        if digits.count <= 4 {
            // "#123" is far more often an issue number than a color. A short form counts
            // when it has a letter (#0AF) or is a gray such as #000 or #333.
            let isGray = digits.count == 3 && Set(digits).count == 1
            guard isGray || digits.contains(where: \.isLetter) else { return nil }
        }
        // Short forms repeat each digit: #1AF is #11AAFF.
        let expanded = digits.count <= 4 ? String(digits.flatMap { [$0, $0] }) : String(digits)
        guard let value = UInt64(expanded, radix: 16) else { return nil }
        let hasAlpha = expanded.count == 8
        let byte: (Int) -> Double = { Double((value >> UInt64($0)) & 0xFF) / 255 }
        return hasAlpha
            ? RGBAColor(red: byte(24), green: byte(16), blue: byte(8), alpha: byte(0))
            : RGBAColor(red: byte(16), green: byte(8), blue: byte(0))
    }

    /// A number, or a percentage of `scale`.
    private static func component(_ text: String, scale: Double) -> Double? {
        if text.hasSuffix("%") {
            return Double(text.dropLast()).map { $0 / 100 * scale }
        }
        return Double(text)
    }

    private static func alpha(_ arguments: [String]) -> Double? {
        guard arguments.count == 4 else { return 1 }
        return component(arguments[3], scale: 1).map { min(max($0, 0), 1) }
    }

    private static func rgb(_ arguments: [String]) -> RGBAColor? {
        guard arguments.count == 3 || arguments.count == 4, let alpha = alpha(arguments) else { return nil }
        let channels = arguments.prefix(3).compactMap { component($0, scale: 255) }
        guard channels.count == 3, channels.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return RGBAColor(red: channels[0] / 255, green: channels[1] / 255, blue: channels[2] / 255, alpha: alpha)
    }

    private static func hsl(_ arguments: [String]) -> RGBAColor? {
        guard arguments.count == 3 || arguments.count == 4, let alpha = alpha(arguments) else { return nil }
        let hueText = arguments[0].hasSuffix("deg") ? String(arguments[0].dropLast(3)) : arguments[0]
        guard let degrees = Double(hueText),
              arguments[1].hasSuffix("%"), arguments[2].hasSuffix("%"),
              let saturation = component(arguments[1], scale: 1), (0...1).contains(saturation),
              let lightness = component(arguments[2], scale: 1), (0...1).contains(lightness)
        else { return nil }
        let hue = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let second = chroma * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
        let (red, green, blue): (Double, Double, Double)
        switch hue {
        case ..<1: (red, green, blue) = (chroma, second, 0)
        case ..<2: (red, green, blue) = (second, chroma, 0)
        case ..<3: (red, green, blue) = (0, chroma, second)
        case ..<4: (red, green, blue) = (0, second, chroma)
        case ..<5: (red, green, blue) = (second, 0, chroma)
        default: (red, green, blue) = (chroma, 0, second)
        }
        let offset = lightness - chroma / 2
        return RGBAColor(red: red + offset, green: green + offset, blue: blue + offset, alpha: alpha)
    }
}
