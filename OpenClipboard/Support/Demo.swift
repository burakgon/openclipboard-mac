import AppKit
import CoreImage.CIFilterBuiltins
import OpenClipboardKit
import SwiftUI

/// A stand-in history for screenshots and for trying the interface.
///
/// `OpenClipboard --demo` starts the app with sample clips in a throwaway database. It
/// watches a pasteboard of its own instead of the real one, and does not touch the real
/// history or settings, so nothing the user has copied can end up in a screenshot. More
/// arguments set up a scene:
///
///     --show                 open the shelf
///     --appearance dark      force light or dark
///     --backdrop             cover the screen with the default wallpaper, behind the shelf
///     --search "invoice"     type into the search field
///     --filter images        choose a filter
///     --keys "right right space"   press keys, one every 0.3 s
///     --onboarding           show the welcome window
///     --settings history     show a pane of the settings window
///     --passive              never take the keyboard focus (for unattended screenshots)
///     --trusted              show the shelf as it is with the permission to paste
///     --untrusted            and as it is without
///     --paused               show the app as it is while recording is paused
///     --update ready         show the interface as it is with an update downloaded
///                            ("available": found, not downloaded)
///     --dry-paste FILE       instead of pressing ⌘V, write the name of the app that would
///                            have received it to FILE
enum Demo {
    static let isEnabled = CommandLine.arguments.contains("--demo")

    /// The name of the private pasteboard the demo watches in place of the system one.
    static let pasteboardName = "com.burakgon.OpenClipboard.demo"

    static func value(of flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + 1)
        else { return nil }
        return CommandLine.arguments[index + 1]
    }

    static func has(_ flag: String) -> Bool { CommandLine.arguments.contains(flag) }

    static var folder: URL { URL(fileURLWithPath: "/tmp/OpenClipboard Demo") }

    static var settingsDefaults: UserDefaults {
        let suite = "com.burakgon.OpenClipboard.demo"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        defaults.set(!has("--onboarding"), forKey: "hasCompletedOnboarding")
        return defaults
    }

    static func makeStore() throws -> HistoryStore {
        try? FileManager.default.removeItem(at: folder)
        return try HistoryStore(fileURL: folder.appending(path: "History.sqlite"))
    }

    // MARK: - Sample clips

    private struct Sample {
        var contents: ClipContents
        var app: (id: String, name: String)
        var age: TimeInterval
        var isPinned = false
    }

    private static let safari = ("com.apple.Safari", "Safari")
    private static let notes = ("com.apple.Notes", "Notes")
    private static let xcode = ("com.apple.dt.Xcode", "Xcode")
    private static let terminal = ("com.apple.Terminal", "Terminal")
    private static let finder = ("com.apple.finder", "Finder")
    private static let preview = ("com.apple.Preview", "Preview")
    private static let mail = ("com.apple.mail", "Mail")
    private static let messages = ("com.apple.MobileSMS", "Messages")
    private static let colorMeter = ("com.apple.DigitalColorMeter", "Digital Color Meter")
    private static let screenshot = ("com.apple.screenshot.launcher", "Screenshot")

    private static func text(_ string: String, rich: Bool = false) -> ClipContents {
        var item = [ClipRepresentation(type: ClipType.plainText, data: Data(string.utf8))]
        if rich, let rtf = richText(string) {
            item.insert(ClipRepresentation(type: ClipType.rtf, data: rtf), at: 0)
        }
        return [item]
    }

    /// Text the way an app in dark mode copies it: with its color, white, and no background.
    private static func textFromDarkMode(_ string: String) -> ClipContents {
        let attributed = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white,
        ])
        var item = [ClipRepresentation(type: ClipType.plainText, data: Data(string.utf8))]
        if let rtf = attributed.rtf(from: NSRange(location: 0, length: attributed.length)) {
            item.insert(ClipRepresentation(type: ClipType.rtf, data: rtf), at: 0)
        }
        return [item]
    }

    private static func picture(_ data: Data) -> ClipContents {
        [[ClipRepresentation(type: ClipType.png, data: data)]]
    }

    private static func files(_ urls: [URL]) -> ClipContents {
        urls.map { [ClipRepresentation(type: ClipType.fileURL, data: $0.dataRepresentation)] }
    }

    static func populate(_ store: HistoryStore) async {
        let documents = URL(fileURLWithPath: "/tmp/Launch Kit")
        try? FileManager.default.removeItem(at: documents)
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let guidelines = documents.appending(path: "Brand Guidelines.pdf")
        let poster = documents.appending(path: "Poster.png")
        let releaseNotes = documents.appending(path: "Release Notes.md")
        writePDF(to: guidelines)
        try? artwork(.poster, width: 1200, height: 1600).write(to: poster)
        try? Data("# 1.0\n\nThe first release.\n".utf8).write(to: releaseNotes)

        let swift = """
            func greet(_ name: String) -> String {
                let hour = Calendar.current.component(.hour, from: .now)
                let greeting = hour < 12 ? "Good morning" : "Hello"
                return "\\(greeting), \\(name)!"
            }
            """
        let json = """
            {
              "name": "openclipboard",
              "version": "1.0.0",
              "license": "MIT",
              "private": false
            }
            """
        let letter = """
            Hi Dana,

            Thanks for the quick turnaround on the launch plan. I read it on the train this morning and \
            I think we are in great shape. Two small things before Friday: the pricing page still shows \
            last year's numbers, and the demo video needs captions.

            Talk soon,
            Alex
            """

        // Oldest first: recording them in this order leaves the last one at the front.
        let samples: [Sample] = [
            Sample(contents: text("The best way to predict the future is to invent it."), app: safari, age: 86_400 * 9),
            Sample(contents: picture(qrCode("https://github.com/burakgon/openclipboard-mac")), app: safari, age: 86_400 * 8),
            Sample(contents: picture(artwork(.specimen, width: 1400, height: 1000)), app: preview, age: 86_400 * 7),
            Sample(contents: text("hsl(152, 58%, 38%)"), app: colorMeter, age: 86_400 * 6),
            Sample(contents: files([releaseNotes]), app: finder, age: 86_400 * 4),
            Sample(contents: text("mailto:hello@example.com"), app: mail, age: 86_400 * 3),
            Sample(contents: picture(artwork(.chart, width: 1200, height: 800)), app: preview, age: 86_400 * 2),
            Sample(contents: text(json), app: xcode, age: 86_400 + 7200),
            Sample(contents: text("Best regards,\nAlex Morgan\nalex@example.com"), app: mail, age: 86_400, isPinned: true),
            Sample(contents: text("https://developer.apple.com/design/human-interface-guidelines"), app: safari, age: 3600 * 9),
            Sample(contents: text(letter, rich: true), app: mail, age: 3600 * 5),
            Sample(contents: textFromDarkMode("Sounds good, see you at seven. I will bring the charger 😄"), app: messages, age: 3600 * 4),
            Sample(contents: text("#0A84FF"), app: colorMeter, age: 3600 * 3),
            Sample(contents: files([guidelines, poster, releaseNotes]), app: finder, age: 3600 * 2),
            Sample(contents: text("git log --oneline --graph --decorate -20"), app: terminal, age: 3600),
            Sample(contents: picture(artwork(.poster, width: 1200, height: 1600)), app: preview, age: 60 * 38),
            Sample(contents: text("Thursday, 3:30 PM"), app: messages, age: 60 * 21),
            Sample(contents: files([guidelines]), app: finder, age: 60 * 12),
            Sample(contents: text("#FF5A36"), app: colorMeter, age: 60 * 7, isPinned: true),
            Sample(contents: text(swift), app: xcode, age: 60 * 4),
            Sample(contents: text("https://github.com/burakgon/openclipboard-mac"), app: safari, age: 95),
            Sample(contents: picture(artwork(.window, width: 1600, height: 1040)), app: screenshot, age: 40),
            Sample(
                contents: text("Ship list for Friday\n• Finish the onboarding copy\n• Record the demo video\n• Reply to Dana about the launch", rich: true),
                app: notes, age: 6),
        ]

        let now = Date()
        for sample in samples {
            let snapshot = PasteboardSnapshot(contents: sample.contents, appBundleID: sample.app.id, appName: sample.app.name)
            guard let draft = ClipClassifier.draft(from: snapshot),
                  let item = try? await store.record(draft, at: now.addingTimeInterval(-sample.age))
            else { continue }
            if sample.isPinned { try? await store.setPinned(true, id: item.id) }
        }
    }

    private static func richText(_ string: String) -> Data? {
        let attributed = NSMutableAttributedString(string: string, attributes: [
            .font: NSFont(name: "Georgia", size: 15) ?? NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.black,
        ])
        if let firstLine = string.split(whereSeparator: \.isNewline).first {
            attributed.addAttribute(
                .font, value: NSFont(name: "Georgia-Bold", size: 19) ?? NSFont.boldSystemFont(ofSize: 19),
                range: NSRange(location: 0, length: firstLine.utf16.count))
        }
        return attributed.rtf(from: NSRange(location: 0, length: attributed.length))
    }

    // MARK: - Sample pictures

    private enum Artwork {
        /// A flat geometric poster.
        case poster
        /// A type specimen.
        case specimen
        case chart
        /// What a screenshot of a window looks like.
        case window
    }

    private static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static func draw(width: Int, height: Int, _ body: (CGContext, CGSize) -> Void) -> Data {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return Data() }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        body(context, CGSize(width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return Data() }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
    }

    private static func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private static func artwork(_ style: Artwork, width: Int, height: Int) -> Data {
        draw(width: width, height: height) { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            switch style {
            case .poster:
                context.setFillColor(color(0xF2EEE6))
                context.fill(bounds)
                context.setFillColor(color(0xE5482D))
                context.fillEllipse(in: CGRect(x: size.width * 0.16, y: size.height * 0.4, width: size.width * 0.68, height: size.width * 0.68))
                context.setFillColor(color(0x171717))
                context.fill(CGRect(x: size.width * 0.16, y: size.height * 0.2, width: size.width * 0.68, height: size.height * 0.045))
                context.fill(CGRect(x: size.width * 0.16, y: size.height * 0.12, width: size.width * 0.36, height: size.height * 0.045))
                context.setFillColor(color(0xF0B429))
                context.fill(CGRect(x: size.width * 0.66, y: size.height * 0.12, width: size.width * 0.18, height: size.height * 0.045))

            case .specimen:
                context.setFillColor(color(0xF5F1E8))
                context.fill(bounds)
                let serif = NSFont.systemFont(ofSize: size.height * 0.5, weight: .semibold).fontDescriptor.withDesign(.serif)
                    .flatMap { NSFont(descriptor: $0, size: size.height * 0.5) } ?? NSFont.systemFont(ofSize: size.height * 0.5)
                NSAttributedString(string: "Aa", attributes: [.font: serif, .foregroundColor: NSColor(cgColor: color(0x1A1A1A)) ?? .black])
                    .draw(at: CGPoint(x: size.width * 0.09, y: size.height * 0.2))
                NSAttributedString(string: "New York  ·  Semibold", attributes: [
                    .font: NSFont.systemFont(ofSize: size.height * 0.042, weight: .medium),
                    .foregroundColor: NSColor(cgColor: color(0x1A1A1A, 0.55)) ?? .gray,
                ]).draw(at: CGPoint(x: size.width * 0.1, y: size.height * 0.11))
                context.setFillColor(color(0xE5482D))
                context.fill(CGRect(x: size.width * 0.1, y: size.height * 0.82, width: size.width * 0.07, height: size.height * 0.022))

            case .chart:
                context.setFillColor(color(0xFFFFFF))
                context.fill(bounds)
                let values: [CGFloat] = [0.32, 0.46, 0.4, 0.58, 0.71, 0.64, 0.86]
                let barWidth = size.width * 0.085, gap = size.width * 0.04
                let left = (size.width - CGFloat(values.count) * barWidth - CGFloat(values.count - 1) * gap) / 2
                for (index, value) in values.enumerated() {
                    let rect = CGRect(
                        x: left + CGFloat(index) * (barWidth + gap), y: size.height * 0.16,
                        width: barWidth, height: size.height * 0.66 * value)
                    context.setFillColor(index == values.count - 1 ? color(0x1A1A1A) : color(0xD9DBE0))
                    context.addPath(rounded(rect, barWidth * 0.16))
                    context.fillPath()
                }
                context.setFillColor(color(0xE6E8EC))
                context.fill(CGRect(x: size.width * 0.08, y: size.height * 0.145, width: size.width * 0.84, height: 3))

            case .window:
                context.setFillColor(color(0xDDE1E7))
                context.fill(bounds)
                let window = bounds.insetBy(dx: size.width * 0.07, dy: size.height * 0.1)
                context.setShadow(offset: CGSize(width: 0, height: -18), blur: 60, color: color(0x000000, 0.28))
                context.setFillColor(color(0xFFFFFF))
                context.addPath(rounded(window, 26))
                context.fillPath()
                context.setShadow(offset: .zero, blur: 0, color: nil)

                context.saveGState()
                context.addPath(rounded(window, 26))
                context.clip()
                let sidebarWidth = window.width * 0.26
                context.setFillColor(color(0xF1F2F5))
                context.fill(CGRect(x: window.minX, y: window.minY, width: sidebarWidth, height: window.height))
                for (index, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
                    context.setFillColor(color(hex))
                    context.fillEllipse(in: CGRect(x: window.minX + 30 + CGFloat(index) * 38, y: window.maxY - 56, width: 24, height: 24))
                }
                for row in 0..<6 {
                    let y = window.maxY - 150 - CGFloat(row) * 62
                    let rect = CGRect(x: window.minX + 24, y: y, width: sidebarWidth - 48, height: 44)
                    if row == 1 {
                        context.setFillColor(color(0x0A84FF))
                        context.addPath(rounded(rect, 11))
                        context.fillPath()
                    }
                    context.setFillColor(row == 1 ? color(0xFFFFFF, 0.9) : color(0xC6C9D1))
                    context.addPath(rounded(CGRect(x: rect.minX + 18, y: rect.midY - 7, width: rect.width * [0.6, 0.72, 0.5, 0.66, 0.44, 0.58][row], height: 14), 7))
                    context.fillPath()
                }
                let contentLeft = window.minX + sidebarWidth + 56
                let contentWidth = window.width - sidebarWidth - 112
                context.setFillColor(color(0x1D1D1F))
                context.addPath(rounded(CGRect(x: contentLeft, y: window.maxY - 150, width: contentWidth * 0.5, height: 34), 10))
                context.fillPath()
                for (row, fraction) in [0.96, 0.9, 0.98, 0.62, 0, 0.93, 0.97, 0.84, 0.4].enumerated() where fraction > 0 {
                    context.setFillColor(color(0xD3D6DC))
                    context.addPath(rounded(CGRect(x: contentLeft, y: window.maxY - 232 - CGFloat(row) * 44, width: contentWidth * fraction, height: 16), 8))
                    context.fillPath()
                }
                context.restoreGState()
            }
        }
    }

    private static func qrCode(_ string: String) -> Data {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return Data() }
        let scale = 880 / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let code = CIContext().createCGImage(scaled, from: scaled.extent) else { return Data() }
        return draw(width: 1000, height: 1000) { context, size in
            context.setFillColor(color(0xFFFFFF))
            context.fill(CGRect(origin: .zero, size: size))
            context.interpolationQuality = .none
            context.draw(code, in: CGRect(x: 60, y: 60, width: 880, height: 880))
        }
    }

    private static func writePDF(to url: URL) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        context.beginPDFPage(nil)
        context.setFillColor(color(0xF4F1EA))
        context.fill(box)
        context.setFillColor(color(0xE5482D))
        context.fill(CGRect(x: 56, y: 96, width: 86, height: 86))
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSAttributedString(string: "Brand\nGuidelines", attributes: [
            .font: NSFont.systemFont(ofSize: 66, weight: .bold), .foregroundColor: NSColor(white: 0.09, alpha: 1),
        ]).draw(at: CGPoint(x: 52, y: 540))
        NSAttributedString(string: "2026 Edition", attributes: [
            .font: NSFont.systemFont(ofSize: 21, weight: .medium), .foregroundColor: NSColor(white: 0.09, alpha: 0.55),
        ]).draw(at: CGPoint(x: 56, y: 492))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
    }
}

/// Sets up the scene the demo arguments describe, once the app is running.
final class DemoDirector {
    private let shelf: ShelfController
    private var backdrop: NSWindow?

    init(shelf: ShelfController) {
        self.shelf = shelf
    }

    func run() {
        // A running demo can be driven from outside, to stage one scene after another:
        // the object of the notification is a key name, as in --keys.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.burakgon.OpenClipboard.demo"), object: nil, queue: .main
        ) { [weak self] notification in
            guard let command = notification.object as? String else { return }
            MainActor.assumeIsolated { self?.press(command) }
        }
        if let appearance = Demo.value(of: "--appearance") {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if let file = Demo.value(of: "--dry-paste") {
            shelf.sendPasteKeystroke = {
                let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nothing"
                try? "\(name)\n".write(toFile: file, atomically: true, encoding: .utf8)
            }
        }
        if Demo.has("--backdrop") { showBackdrop() }
        guard Demo.has("--show") else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            shelf.show()
            try? await Task.sleep(for: .milliseconds(600))
            if let filter = Demo.value(of: "--filter"),
               let match = ShelfModel.Filter.allCases.first(where: { $0.title.lowercased() == filter.lowercased() }) {
                shelf.model.filter = match
            }
            if let search = Demo.value(of: "--search") {
                shelf.model.searchText = search
            }
            for key in (Demo.value(of: "--keys") ?? "").split(separator: " ") {
                try? await Task.sleep(for: .milliseconds(300))
                press(String(key))
            }
        }
    }

    /// Does what a key would do. The keys are named as in `--keys "right space"`.
    private func press(_ name: String) {
        let model = shelf.model
        switch name {
        case "left": model.moveSelection(by: -1)
        case "right": model.moveSelection(by: 1)
        case "end": model.selectLast()
        case "space": shelf.togglePreview()
        case "tab": model.cycleFilter(forward: true)
        case "cmd": withAnimation(.snappy(duration: 0.16)) { model.isCommandDown.toggle() }
        case "pin": if let item = model.selectedItem { shelf.togglePin(item) }
        case "delete": if let item = model.selectedItem { shelf.delete(item) }
        case "return": if let item = model.selectedItem { shelf.paste(item) }
        case "just-copy": shelf.justCopy()
        case "esc": shelf.dismissPasteRequest()
        case "show": shelf.show()
        case "hide": shelf.hide()
        default:
            if name.hasPrefix("search:") { model.searchText = String(name.dropFirst(7)) }
        }
    }

    /// The default macOS wallpaper behind the shelf, so screenshots show neither the
    /// desktop nor the windows of whoever takes them.
    private func showBackdrop() {
        guard let screen = NSScreen.main else { return }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.backgroundColor = .windowBackgroundColor

        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.contents = NSImage(contentsOfFile: "/System/Library/CoreServices/DefaultDesktop.heic")
        view.layer?.contentsGravity = .resizeAspectFill
        view.layer?.masksToBounds = true
        window.contentView = view
        window.orderFrontRegardless()
        backdrop = window
    }
}
