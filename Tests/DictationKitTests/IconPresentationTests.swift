import XCTest
@testable import DictationKit

final class IconPresentationTests: XCTestCase {

    private let accuracy = 1e-9

    // MARK: - Idle

    func testStartsNormalAndStatic() {
        let model = IconPresentationModel(now: 100)
        XCTAssertEqual(model.kind, .normal)
        XCTAssertEqual(model.frame(at: 100), .normal)
        XCTAssertNil(model.frame(at: 100).color)
        XCTAssertFalse(model.isAnimating(at: 100))
    }

    func testInitialIdleOutcomeProducesNoAnimation() {
        var model = IconPresentationModel(now: 0)
        model.update(outcome: .idle, now: 5)
        XCTAssertEqual(model.kind, .normal)
        XCTAssertEqual(model.frame(at: 5), .normal)
    }

    // MARK: - Recording

    func testRecordingIsSolidRedAndStatic() {
        var model = IconPresentationModel(now: 0)
        model.update(state: .recording, now: 10)
        let frame = model.frame(at: 10)
        XCTAssertEqual(frame.color, .recordingRed)
        XCTAssertEqual(frame.normalWeight, 0, accuracy: accuracy)
        // Solid: no redraw timer needed, and it holds until the next transition.
        XCTAssertFalse(model.isAnimating(at: 10))
        XCTAssertEqual(model.frame(at: 30).color, .recordingRed)
    }

    // MARK: - Processing (one continuous blink across transcribing and injecting)

    func testProcessingBlinksYellowOnOff() {
        var model = IconPresentationModel(now: 0)
        model.update(state: .transcribing, now: 0)
        // On for the first half of the 1 Hz cycle, crisply off for the second — no ramp.
        XCTAssertEqual(model.frame(at: 0).color, .processingYellow)
        XCTAssertEqual(model.frame(at: 0).normalWeight, 0, accuracy: accuracy)      // solid on
        XCTAssertEqual(model.frame(at: 0.25).normalWeight, 0, accuracy: accuracy)   // still on
        XCTAssertEqual(model.frame(at: 0.5), .normal)                               // off: no dot
        XCTAssertEqual(model.frame(at: 0.75), .normal)                              // still off
        XCTAssertEqual(model.frame(at: 1.0).color, .processingYellow)              // snaps back on
        XCTAssertTrue(model.isAnimating(at: 100))  // blinks until the next transition
    }

    func testProcessingBlinkIsContinuousFromTranscribingToInjecting() {
        var model = IconPresentationModel(now: 0)
        model.update(state: .transcribing, now: 0)
        model.update(state: .injecting, now: 0.5)  // must NOT restart the blink clock
        XCTAssertEqual(model.kind, .processing)
        // If the clock had restarted at 0.5, elapsed at t=0.7 would be 0.2 → on (yellow).
        // Continuity means elapsed is 0.7 → the off half of the cycle (no dot).
        XCTAssertEqual(model.frame(at: 0.7), .normal)
    }

    // MARK: - Success (solid blue 1s, fade to normal over 1s)

    func testSuccessHoldsBlueThenFadesToNormal() {
        var model = IconPresentationModel(now: 0)
        model.update(outcome: .injected("hi"), now: 0)

        XCTAssertEqual(model.frame(at: 0).color, .successBlue)
        XCTAssertEqual(model.frame(at: 0).normalWeight, 0, accuracy: accuracy)
        XCTAssertEqual(model.frame(at: 0.99).normalWeight, 0, accuracy: accuracy)   // still solid
        XCTAssertEqual(model.frame(at: 1.0).normalWeight, 0, accuracy: accuracy)    // fade begins
        XCTAssertEqual(model.frame(at: 1.5).normalWeight, 0.5, accuracy: accuracy)  // halfway back
        XCTAssertEqual(model.frame(at: 2.0), .normal)                               // fully normal
        XCTAssertEqual(model.frame(at: 5.0), .normal)
    }

    func testSuccessAnimatesForExactlyTwoSeconds() {
        var model = IconPresentationModel(now: 0)
        model.update(outcome: .injected("hi"), now: 0)
        XCTAssertTrue(model.isAnimating(at: 1.999))
        XCTAssertFalse(model.isAnimating(at: 2.0))
    }

    func testSuccessSurvivesTheImmediateIdleThatFollowsIt() {
        // `finish` emits `.injected` then sets `.idle`; the idle must not erase success.
        var model = IconPresentationModel(now: 0)
        model.update(outcome: .injected("hi"), now: 0)
        model.update(state: .idle, now: 0.001)
        XCTAssertEqual(model.kind, .success)
        XCTAssertEqual(model.frame(at: 0.5).color, .successBlue)
    }

    // MARK: - Failure (crisp orange blink 2 Hz for 5s, then a short fade out)

    func testFailureBlinksOrangeThenFadesOut() {
        var model = IconPresentationModel(now: 0)
        model.update(outcome: .failed("boom"), now: 0)
        // Crisp 2 Hz blink: on the first quarter-second, off the next — no ramp.
        XCTAssertEqual(model.frame(at: 0).color, .failureOrange)
        XCTAssertEqual(model.frame(at: 0).normalWeight, 0, accuracy: accuracy)   // on
        XCTAssertEqual(model.frame(at: 0.3), .normal)                            // off half
        // Then a short fade out to normal (the end-state fade), starting from full.
        XCTAssertEqual(model.frame(at: 5.0).color, .failureOrange)
        XCTAssertEqual(model.frame(at: 5.0).normalWeight, 0, accuracy: accuracy)
        XCTAssertEqual(model.frame(at: 5.25).normalWeight, 0.5, accuracy: accuracy)
        XCTAssertEqual(model.frame(at: 5.5), .normal)
        XCTAssertTrue(model.isAnimating(at: 5.499))
        XCTAssertFalse(model.isAnimating(at: 5.5))
    }

    func testAllFailuresIncludingInterruptedCapturesUseTheFailureIcon() {
        for reason in ["boom", "microphone changed — try again", "microphone reset — try again"] {
            var model = IconPresentationModel(now: 0)
            model.update(outcome: .failed(reason), now: 0)
            XCTAssertEqual(model.kind, .failure, "reason: \(reason)")
        }
    }

    // MARK: - No speech / short capture (one brief orange flash that fades out)

    func testNoSpeechFlashesOrangeThenFadesOut() {
        var model = IconPresentationModel(now: 0)
        model.update(outcome: .noAudio, now: 0)
        XCTAssertEqual(model.frame(at: 0).color, .failureOrange)
        XCTAssertEqual(model.frame(at: 0).normalWeight, 0, accuracy: accuracy)      // snaps on full
        XCTAssertEqual(model.frame(at: 0.125).color, .failureOrange)
        XCTAssertEqual(model.frame(at: 0.125).normalWeight, 0.5, accuracy: accuracy)  // fading out
        XCTAssertEqual(model.frame(at: 0.25), .normal)
        XCTAssertTrue(model.isAnimating(at: 0.249))
        XCTAssertFalse(model.isAnimating(at: 0.25))
    }

    // MARK: - New recording interrupts a result, invalidating its deadline

    func testNewRecordingDuringSuccessSwitchesToRedImmediately() {
        var model = IconPresentationModel(now: 0)
        model.update(outcome: .injected("hi"), now: 0)
        model.update(state: .recording, now: 0.5)
        XCTAssertEqual(model.kind, .recording)
        XCTAssertEqual(model.frame(at: 0.6).color, .recordingRed)
        // The old success deadline was t=2; the frame there must be red, not normal —
        // a stale result deadline can never restore idle over a live recording.
        XCTAssertEqual(model.frame(at: 2.0).color, .recordingRed)
        XCTAssertEqual(model.frame(at: 10).color, .recordingRed)
    }

    func testNewRecordingDuringFailureSwitchesToRedImmediately() {
        var model = IconPresentationModel(now: 0)
        model.update(outcome: .failed("boom"), now: 0)
        model.update(state: .recording, now: 1.0)
        XCTAssertEqual(model.frame(at: 5.0).color, .recordingRed)  // past the old 5s deadline
    }

    // MARK: - Repeated results animate afresh

    func testASecondResultRestartsItsAnimation() {
        var model = IconPresentationModel(now: 0)
        model.update(outcome: .injected("hi"), now: 0)
        XCTAssertEqual(model.frame(at: 2.5), .normal)  // first result finished

        model.update(outcome: .noAudio, now: 3.0)
        XCTAssertEqual(model.frame(at: 3.1).color, .failureOrange)
        XCTAssertEqual(model.frame(at: 3.25), .normal)
    }

    // MARK: - A full ordinary cycle

    func testFullCycleRecordingProcessingSuccessBackToNormal() {
        var model = IconPresentationModel(now: 0)
        model.update(state: .recording, now: 0)
        XCTAssertEqual(model.frame(at: 0).color, .recordingRed)
        model.update(state: .transcribing, now: 1)
        XCTAssertEqual(model.frame(at: 1).color, .processingYellow)
        model.update(state: .injecting, now: 2)
        XCTAssertEqual(model.frame(at: 2).color, .processingYellow)
        model.update(outcome: .injected("done"), now: 2)
        XCTAssertEqual(model.frame(at: 2).color, .successBlue)
        model.update(state: .idle, now: 2)               // ignored
        XCTAssertEqual(model.frame(at: 4.0), .normal)    // success fully faded
        XCTAssertFalse(model.isAnimating(at: 4.0))
    }

    func testCustomColorsDriveEveryDotKind() {
        let colors = StatusDotColors(
            recording: IconColor(hex: "#010101")!,
            processing: IconColor(hex: "#020202")!,
            success: IconColor(hex: "#030303")!,
            failure: IconColor(hex: "#040404")!
        )
        var model = IconPresentationModel(now: 0, colors: colors)
        model.update(state: .recording, now: 0)
        XCTAssertEqual(model.frame(at: 0).color, colors.recording)
        model.update(state: .transcribing, now: 1)
        XCTAssertEqual(model.frame(at: 1).color, colors.processing)
        model.update(outcome: .injected("ok"), now: 2)
        XCTAssertEqual(model.frame(at: 2).color, colors.success)
        model.update(outcome: .failed("bad"), now: 3)
        XCTAssertEqual(model.frame(at: 3).color, colors.failure)
    }
}
