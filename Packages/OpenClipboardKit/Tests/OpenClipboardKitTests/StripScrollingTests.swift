import Testing

@testable import OpenClipboardKit

/// The numbers of the shelf on a 1736 point wide screen: cards of 204 with 12 between
/// them, 18 of margin, and 1716 points of row.
@Suite struct StripScrollingTests {
    private let width = 1716.0
    private let start = -18.0

    private func scrolling() -> StripScrolling {
        StripScrolling(cardWidth: 204, spacing: 12, margin: 18)
    }

    @Test func aCardThatIsInViewNeedsNoScroll() {
        var scrolling = scrolling()
        #expect(scrolling.reveal(index: 0, visibleMinX: start, visibleWidth: width, now: 0) == nil)
        // The seventh card ends at 1500, well inside.
        #expect(scrolling.reveal(index: 6, visibleMinX: start, visibleWidth: width, now: 0) == nil)
    }

    @Test func revealsTheNearerEdgeAndNoFurther() {
        var scrolling = scrolling()
        // The eighth card ends at 1716: it needs 36 more points to clear the margin.
        #expect(scrolling.reveal(index: 7, visibleMinX: start, visibleWidth: width, now: 0) == .glide(to: 36))
        // Back to the first card from far away: the very start.
        #expect(scrolling.reveal(index: 0, visibleMinX: 1494, visibleWidth: width, now: 10) == .glide(to: 0))
    }

    @Test func aSingleStepGlidesAndAHeldKeySnaps() {
        var scrolling = scrolling()
        #expect(scrolling.reveal(index: 7, visibleMinX: start, visibleWidth: width, now: 0) == .glide(to: 36))
        #expect(scrolling.reveal(index: 8, visibleMinX: 18, visibleWidth: width, now: 0.05) == .snap(to: 252))
        #expect(scrolling.reveal(index: 9, visibleMinX: 234, visibleWidth: width, now: 0.1) == .snap(to: 468))
        // After a pause it is a single step again.
        #expect(scrolling.reveal(index: 10, visibleMinX: 450, visibleWidth: width, now: 2) == .glide(to: 684))
    }

    @Test func aRequestDuringAnAnimationWaitsUntilTheRowRests() {
        var scrolling = scrolling()
        #expect(scrolling.reveal(index: 7, visibleMinX: start, visibleWidth: width, now: 0) != nil)
        #expect(scrolling.phaseChanged(to: .animating) == false)
        #expect(scrolling.reveal(index: 14, visibleMinX: 0, visibleWidth: width, now: 0.1) == nil)
        // At rest the caller is told to ask again, once.
        #expect(scrolling.phaseChanged(to: .resting) == true)
        #expect(scrolling.reveal(index: 14, visibleMinX: 18, visibleWidth: width, now: 0.3) == .snap(to: 1548))
        #expect(scrolling.phaseChanged(to: .resting) == false)
    }

    @Test func aScrollByHandStaysWhereItEnded() {
        var scrolling = scrolling()
        // The user scrolls away from the selected first card, and lets go.
        #expect(scrolling.phaseChanged(to: .byHand) == false)
        #expect(scrolling.phaseChanged(to: .resting) == false)
        #expect(scrolling.isHandScrolled)
        // Nothing brings the row back, not even a change of the list or of the selection
        // that the user did not make.
        #expect(scrolling.reveal(index: 0, visibleMinX: 862, visibleWidth: width, now: 5) == nil)
    }

    @Test func aScrollByHandCancelsAWaitingRequest() {
        var scrolling = scrolling()
        _ = scrolling.reveal(index: 7, visibleMinX: start, visibleWidth: width, now: 0)
        _ = scrolling.phaseChanged(to: .animating)
        #expect(scrolling.reveal(index: 14, visibleMinX: 0, visibleWidth: width, now: 0.1) == nil)
        // The user grabs the row in mid-flight.
        _ = scrolling.phaseChanged(to: .byHand)
        #expect(scrolling.phaseChanged(to: .resting) == false)
    }

    @Test func choosingAClipLetsTheRowFollowTheSelectionAgain() {
        var scrolling = scrolling()
        _ = scrolling.phaseChanged(to: .byHand)
        _ = scrolling.phaseChanged(to: .resting)
        scrolling.userChose()
        #expect(!scrolling.isHandScrolled)
        // The fifth card starts at 864, right at the edge of what is visible: it gets
        // its margin.
        #expect(scrolling.reveal(index: 4, visibleMinX: 862, visibleWidth: width, now: 5) == .glide(to: 864))
    }

    @Test func nothingToRevealWithoutASelectionOrALayout() {
        var scrolling = scrolling()
        #expect(scrolling.reveal(index: nil, visibleMinX: start, visibleWidth: width, now: 0) == nil)
        #expect(scrolling.reveal(index: 9, visibleMinX: 0, visibleWidth: 0, now: 0) == nil)
    }
}
