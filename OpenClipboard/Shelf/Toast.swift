import AppKit
import SwiftUI

/// A short confirmation near the bottom of the screen, such as "Copied". It never takes
/// the keyboard or the mouse, and removes itself.
final class Toast {
    private var panel: AuxiliaryPanel?
    private var dismissal: Task<Void, Never>?

    func show(_ title: String, detail: String?, symbol: String) {
        dismissal?.cancel()
        let panel = panel ?? AuxiliaryPanel(acceptsMouse: false)
        self.panel = panel
        panel.setRootView(ToastView(title: title, detail: detail, symbol: symbol))

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = CGSize(width: 360, height: 96)
        panel.setFrame(
            CGRect(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.minY + 56, width: size.width, height: size.height),
            display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }

        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(detail == nil ? 1.1 : 1.8))
            guard !Task.isCancelled, let panel = self?.panel else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }
}

private struct ToastView: View {
    let title: String
    let detail: String?
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tint)
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 42)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
