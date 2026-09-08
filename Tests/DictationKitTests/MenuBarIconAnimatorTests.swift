import XCTest
@testable import DictationKit

@MainActor
final class MenuBarIconAnimatorTests: XCTestCase {
    final class Clock { var now: TimeInterval = 0 }

    func testOutcomeThenIdleKeepsResultAndExpiresItsLabel() {
        let clock = Clock()
        var frames: [(IconRenderSpec, String)] = []
        let animator = MenuBarIconAnimator(clock: { clock.now }) { frames.append(($0, $1)) }
        animator.update(outcome: .injected("text"))
        animator.update(state: .idle)
        XCTAssertEqual(frames.last?.0.color, IconColor.successBlue)
        XCTAssertEqual(frames.last?.1, "Dictation — inserted")
        XCTAssertTrue(animator.isTimerRunning)

        clock.now = 2
        animator.tick()
        XCTAssertEqual(frames.last?.0, .normal)
        XCTAssertEqual(frames.last?.1, "Dictation")
        XCTAssertFalse(animator.isTimerRunning)
    }

    func testOldResultTickCannotOverrideNewRecording() {
        let clock = Clock()
        var frames: [IconRenderSpec] = []
        let animator = MenuBarIconAnimator(clock: { clock.now }) { frame, _ in frames.append(frame) }
        animator.update(outcome: .failed("failure"))
        clock.now = 1
        animator.update(state: .recording)
        XCTAssertEqual(frames.last?.color, IconColor.recordingRed)

        clock.now = 6
        animator.tick()
        XCTAssertEqual(frames.last?.color, IconColor.recordingRed)
        XCTAssertFalse(animator.isTimerRunning)
    }

    func testStopInvalidatesTimerAndMakesQueuedTicksNoOps() {
        let clock = Clock()
        var count = 0
        let animator = MenuBarIconAnimator(clock: { clock.now }) { _, _ in count += 1 }
        animator.update(state: .transcribing)
        XCTAssertTrue(animator.isTimerRunning)
        let countAtStop = count
        animator.stop()
        animator.tick()
        animator.update(outcome: .injected("late"))
        XCTAssertFalse(animator.isTimerRunning)
        XCTAssertEqual(count, countAtStop)
    }

    func testPreviewExpiresToUnderlyingStateAndDictationCancelsIt() {
        let clock = Clock()
        var frames: [(IconRenderSpec, String)] = []
        let animator = MenuBarIconAnimator(clock: { clock.now }) { frames.append(($0, $1)) }
        let custom = IconColor(hex: "#A1B2C3")!
        animator.preview(color: custom, name: "Success")
        XCTAssertEqual(frames.last?.0.color, custom)
        XCTAssertEqual(frames.last?.1, "Preview — Success")

        clock.now = 2
        animator.tick()
        XCTAssertEqual(frames.last?.0, .normal)
        XCTAssertFalse(animator.isTimerRunning)

        animator.preview(color: custom, name: "Success")
        animator.update(state: .recording)
        XCTAssertEqual(frames.last?.0.color, IconColor.recordingRed)
        XCTAssertEqual(frames.last?.1, "Dictation — recording")
    }

    func testChangedColorsApplyToTheCurrentStateImmediately() {
        let clock = Clock()
        var frames: [IconRenderSpec] = []
        let animator = MenuBarIconAnimator(clock: { clock.now }) { frame, _ in frames.append(frame) }
        animator.update(state: .recording)
        var colors = StatusDotColors.default
        colors.recording = IconColor(hex: "#123456")!
        animator.update(colors: colors)
        XCTAssertEqual(frames.last?.color, colors.recording)
    }
}
