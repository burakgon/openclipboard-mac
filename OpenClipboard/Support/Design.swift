import SwiftUI

/// The measurements of the shelf, in one place so the window and its content agree.
enum Design {
    static let cardWidth: CGFloat = 204
    static let cardHeight: CGFloat = 218
    static let cardSpacing: CGFloat = 12
    static let cardCornerRadius: CGFloat = 20

    /// Room around the cards inside the strip, for the lift and glow of the selected one.
    static let stripInset: CGFloat = 12

    static let shelfCornerRadius: CGFloat = 32
    static let shelfPadding: CGFloat = 14
    /// Space between the first and last card and the ends of the strip, and what is kept
    /// free next to a card that is scrolled into view.
    static let stripMargin: CGFloat = shelfPadding + 4
    /// Gap between the shelf and the edges of the screen.
    static let shelfMargin: CGFloat = 10
    static let topBarHeight: CGFloat = 34
    static let hintBarHeight: CGFloat = 20

    static var shelfHeight: CGFloat {
        shelfPadding + topBarHeight + cardHeight + stripInset * 2 + hintBarHeight + shelfPadding - 2
    }

    /// Transparent space above the shelf inside its window, for the little overshoot of
    /// the spring it appears with. Kept small: what is behind it should stay clickable.
    static let shelfHeadroom: CGFloat = 14

    static let appear = Animation.spring(duration: 0.36, bounce: 0.2)
    static let disappear = Animation.easeIn(duration: 0.14)
    static let select = Animation.snappy(duration: 0.22, extraBounce: 0.08)
}

extension Color {
    /// The fill of a card: readable over any wallpaper, a little brighter when selected.
    static func cardFill(_ scheme: ColorScheme, isSelected: Bool = false) -> Color {
        if scheme == .dark {
            return Color.white.opacity(isSelected ? 0.16 : 0.09)
        }
        return Color.white.opacity(isSelected ? 0.92 : 0.7)
    }

    static func cardStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.9)
    }

    /// A quiet fill for controls that sit on glass, such as the search field.
    static func controlFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.06)
    }
}
