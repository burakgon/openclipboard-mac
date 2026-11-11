import Foundation

/// The rules for when the row of clips scrolls by itself.
///
/// Two things move the row. The user does, with a trackpad or a mouse wheel, and then it
/// has to stay where they left it. The keyboard does, by moving the selection, and then
/// the row follows just far enough to keep the selected card in view. The two must never
/// fight: once the user has scrolled by hand, the row is not brought back to the selection
/// until they choose a clip again.
///
/// This is plain logic, kept apart from the view that scrolls, so that it can be tested.
/// Every card has the same width, so where a card is follows from its index.
public struct StripScrolling: Sendable {
    public enum Phase: Sendable, Equatable {
        case resting
        /// On its way to where a `Command` sent it.
        case animating
        /// Following the user's fingers or wheel, or coasting after they let go.
        case byHand
    }

    /// A scroll for the view to carry out. Offsets count from the start of the leading margin.
    public enum Command: Sendable, Equatable {
        /// Animated: a single step.
        case glide(to: Double)
        /// At once: one of many steps while a key is held, when an animation would let the
        /// selection run ahead of what is on screen.
        case snap(to: Double)
    }

    /// Steps closer together than this, in seconds, are a held key.
    static let repeatInterval = 0.4

    public let cardWidth: Double
    public let spacing: Double
    /// Free space kept between a revealed card and the edge of the row.
    public let margin: Double

    public private(set) var phase = Phase.resting
    /// True from the moment the user scrolls by hand until they choose a clip.
    public private(set) var isHandScrolled = false
    private var isRevealWaiting = false
    private var lastScroll = -Double.infinity

    public init(cardWidth: Double, spacing: Double, margin: Double) {
        self.cardWidth = cardWidth
        self.spacing = spacing
        self.margin = margin
    }

    /// The user chose a clip, with the keyboard or the mouse. From here on the row follows
    /// the selection again.
    public mutating func userChose() {
        isHandScrolled = false
    }

    /// The scroll that brings the card at `index` into view, if one is needed and allowed.
    ///
    /// - Parameters:
    ///   - visibleMinX: The left edge of what is visible, in the coordinates of the cards:
    ///     zero is the left edge of the first card.
    ///   - now: A clock in seconds, to tell a single step from a held key.
    public mutating func reveal(index: Int?, visibleMinX: Double, visibleWidth: Double, now: Double) -> Command? {
        guard !isHandScrolled, let index, visibleWidth > 0 else { return nil }
        // A scroll that is asked for while another is still animating is not reliably
        // carried out. It waits until the row rests: see `phaseChanged(to:)`.
        if phase == .animating {
            isRevealWaiting = true
            return nil
        }

        let minX = Double(index) * (cardWidth + spacing)
        let maxX = minX + cardWidth
        let target: Double
        if minX - margin < visibleMinX {
            target = minX - margin
        } else if maxX + margin > visibleMinX + visibleWidth {
            target = maxX + margin - visibleWidth
        } else {
            return nil
        }

        let isRepeating = now - lastScroll < Self.repeatInterval
        lastScroll = now
        let offset = target + margin
        return isRepeating ? .snap(to: offset) : .glide(to: offset)
    }

    /// Tells the rules what the row is doing. Returns true when a reveal that had to wait
    /// for an animation should be asked for again now.
    ///
    /// Coming to rest after the user scrolled by hand never returns true. It once did:
    /// the row then slid back to the selected clip a moment after every scroll.
    public mutating func phaseChanged(to newPhase: Phase) -> Bool {
        phase = newPhase
        switch newPhase {
        case .resting:
            defer { isRevealWaiting = false }
            return isRevealWaiting
        case .animating:
            return false
        case .byHand:
            isRevealWaiting = false
            isHandScrolled = true
            return false
        }
    }
}
