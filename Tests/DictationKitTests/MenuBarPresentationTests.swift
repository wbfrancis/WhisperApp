import XCTest
@testable import DictationKit

final class MenuBarPresentationTests: XCTestCase {

    func testStandardEditCommandsExposeNativeResponderSelectors() {
        XCTAssertEqual(StandardEditCommand.all.map(\.selectorName), ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"])
        XCTAssertEqual(StandardEditCommand.all.map(\.key), ["z", "Z", "x", "c", "v", "a"])
    }

    func testFileStatusShowsCommittedProgressAndPause() {
        XCTAssertEqual(FileMenuPresentation.status(for: .running(percent: 42)), "transcribing file — 42%")
        XCTAssertEqual(
            FileMenuPresentation.status(for: .pausedForLiveDictation(percent: 42)),
            "paused for live dictation — 42%"
        )
    }

    func testCueVolumeAppliesTheSameAmplitudeToBothSounds() {
        for volume in CueVolume.allCases {
            let amplitudes = SoundVolumePresentation.amplitudes(for: volume)
            XCTAssertEqual(amplitudes.start, volume.rawValue)
            XCTAssertEqual(amplitudes.stop, volume.rawValue)
        }
    }

    func testPartialResultUsesExternalLabelAndFilenameSuffix() {
        let source = URL(fileURLWithPath: "/tmp/interview.m4a")
        XCTAssertEqual(FileResultPresentation.stateLabel(isPartial: true), "Partial")
        XCTAssertEqual(
            FileResultPresentation.suggestedFilename(sourceURL: source, isPartial: true),
            "interview-partial.txt"
        )
        XCTAssertEqual(
            FileResultPresentation.suggestedFilename(sourceURL: source, isPartial: false),
            "interview.txt"
        )
    }
    // MARK: - Sounds (AC: start and stop sounds play on the transitions)

    func testStartSoundWhenRecordingBegins() {
        XCTAssertEqual(MenuBarPresentation.sound(from: .idle, to: .recording), .start)
    }

    func testStopSoundWhenRecordingEnds() {
        XCTAssertEqual(MenuBarPresentation.sound(from: .recording, to: .transcribing), .stop)
    }

    func testNoSoundOnNonRecordingTransitions() {
        XCTAssertNil(MenuBarPresentation.sound(from: .transcribing, to: .injecting))
        XCTAssertNil(MenuBarPresentation.sound(from: .injecting, to: .idle))
        XCTAssertNil(MenuBarPresentation.sound(from: .idle, to: .idle))
    }

    func testStopSoundEvenIfRecordingGoesStraightToIdle() {
        // A no-audio release ends recording without transcribing; the stop cue still plays.
        XCTAssertEqual(MenuBarPresentation.sound(from: .recording, to: .idle), .stop)
    }

    // MARK: - Presenter (tracks transitions across a full dictation cycle)

    func testPresenterPairsTransitionsAcrossAWholeCycle() {
        var presenter = MenuBarPresenter()

        XCTAssertEqual(presenter.advance(to: .recording), .start)

        XCTAssertEqual(presenter.advance(to: .transcribing), .stop)

        XCTAssertNil(
            presenter.advance(to: .injecting),
            "no cue between the post-recording steps"
        )

        XCTAssertNil(presenter.advance(to: .idle))
    }

    func testPresenterEmitsStartOnlyOnceForRepeatedRecordingRenders() {
        var presenter = MenuBarPresenter()
        XCTAssertEqual(presenter.advance(to: .recording), .start)
        XCTAssertNil(presenter.advance(to: .recording), "already recording: no repeat cue")
    }
}
