import XCTest
@testable import DictationKit

final class TextNormalizerTests: XCTestCase {
    private let normalizer = DeterministicTextNormalizer()

    func testNormalizesWrittenMonthDatesAndTimes() {
        XCTAssertEqual(
            normalizer.normalize("August twenty-fifth twenty twenty-six at three o'clock"),
            "August 25, 2026 at 3:00"
        )
        XCTAssertEqual(normalizer.normalize("August twenty fifth"), "August 25")
        XCTAssertEqual(normalizer.normalize("August 25th 2026"), "August 25, 2026")
        XCTAssertEqual(normalizer.normalize("August 25 2026"), "August 25, 2026")
    }

    func testLeavesRelativeAndNumberOnlyDatesUnchanged() {
        let input = "today, tomorrow, next Tuesday, and 8/25/2026"
        XCTAssertEqual(normalizer.normalize(input), input)
    }

    func testPreservesUnmatchedTextWhitespaceNewlinesAndPunctuationExactly() {
        let input = "Meet  on August twenty-fifth twenty twenty-six.\nThen say: hello!"
        XCTAssertEqual(
            normalizer.normalize(input),
            "Meet  on August 25, 2026.\nThen say: hello!"
        )
    }

    func testDoesNotInferLists() {
        let input = "first apples second pears third plums"
        XCTAssertEqual(normalizer.normalize(input), input)
    }
}
