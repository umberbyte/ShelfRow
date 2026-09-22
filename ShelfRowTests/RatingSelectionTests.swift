import Testing
@testable import ShelfRow

struct RatingSelectionTests {
    @Test func clickingTheCurrentRatingClearsItAndClickingAgainRestoresIt() {
        let cleared = RatingSelection.value(afterClicking: 3, current: 3, maximum: 5)
        let restored = RatingSelection.value(afterClicking: 3, current: cleared, maximum: 5)

        #expect(cleared == 0)
        #expect(restored == 3)
    }

    @Test func clickingAnotherStarChangesTheRatingAndClampsInvalidInput() {
        #expect(RatingSelection.value(afterClicking: 5, current: 2, maximum: 5) == 5)
        #expect(RatingSelection.value(afterClicking: 8, current: 2, maximum: 5) == 5)
        #expect(RatingSelection.value(afterClicking: -1, current: 2, maximum: 5) == 0)
    }
}
