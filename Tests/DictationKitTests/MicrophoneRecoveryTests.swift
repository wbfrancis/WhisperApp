import XCTest
import AVFoundation
@testable import DictationKit

@MainActor
private final class FakeAudioEngineSession: AudioEngineSession {
    enum Failure: Error { case start }

    let configurationChangeObject: AnyObject = NSObject()
    var isRunning = false
    var queuedFormats: [AVAudioFormat?] = []
    var startFailuresRemaining = 0
    var installCount = 0
    var removeCount = 0
    var prepareCount = 0
    var startCount = 0
    var stopCount = 0
    var resetCount = 0
    private var hasTap = false

    private let validFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    var inputFormat: AVAudioFormat? {
        queuedFormats.isEmpty ? validFormat : queuedFormats.removeFirst()
    }

    func installTap(
        format: AVAudioFormat,
        block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        precondition(!hasTap, "a recovery installed a second tap")
        hasTap = true
        installCount += 1
    }

    func removeTap() {
        precondition(hasTap, "a recovery removed a missing tap")
        hasTap = false
        removeCount += 1
    }

    func prepare() { prepareCount += 1 }

    func start() throws {
        startCount += 1
        if startFailuresRemaining > 0 {
            startFailuresRemaining -= 1
            throw Failure.start
        }
        isRunning = true
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }

    func reset() { resetCount += 1 }
}

final class MicrophoneRecoveryTests: XCTestCase {
    @MainActor
    func testResetCoordinatorReportsProgressAndSuccessfulIdleReset() async {
        var statuses: [String] = []
        let coordinator = MicrophoneResetCoordinator {
            .recovered(interruptedCapture: false)
        }
        coordinator.onStatus = { statuses.append($0) }

        await coordinator.performReset()

        XCTAssertEqual(statuses, ["resetting microphone…", "microphone reset"])
    }

    @MainActor
    func testResetCoordinatorReportsEveryTerminalOutcome() async {
        let cases: [(MicrophoneRecoveryOutcome, String)] = [
            (.recovered(interruptedCapture: true), "microphone reset — try again"),
            (.failed(interruptedCapture: false), "microphone reset failed — try again"),
            (.alreadyInProgress, "microphone recovery already in progress"),
        ]

        for (outcome, expected) in cases {
            var statuses: [String] = []
            let coordinator = MicrophoneResetCoordinator { outcome }
            coordinator.onStatus = { statuses.append($0) }
            await coordinator.performReset()
            XCTAssertEqual(statuses, ["resetting microphone…", expected])
        }
    }

    @MainActor
    func testManualResetRestartsTheRealAdapterBoundaryExactlyOnce() async throws {
        let session = FakeAudioEngineSession()
        let source = AVAudioEngineAudioSource(
            session: session,
            recoveryAttemptCount: 2,
            recoveryRetryDelay: .zero
        )
        try source.prewarm()

        let outcome = await source.resetMicrophone()

        XCTAssertEqual(outcome, .recovered(interruptedCapture: false))
        XCTAssertEqual(session.installCount, 2)
        XCTAssertEqual(session.removeCount, 1)
        XCTAssertEqual(session.startCount, 2)
        XCTAssertEqual(session.stopCount, 1)
        XCTAssertEqual(session.resetCount, 1)
    }

    @MainActor
    func testManualResetReportsAndDiscardsAnActiveCapture() async throws {
        let session = FakeAudioEngineSession()
        let source = AVAudioEngineAudioSource(
            session: session,
            recoveryAttemptCount: 1,
            recoveryRetryDelay: .zero
        )
        var reasons: [MicrophoneRecoveryReason] = []
        source.onCaptureInvalidated = { reasons.append($0) }
        try source.startCapture()

        let outcome = await source.resetMicrophone()

        XCTAssertEqual(outcome, .recovered(interruptedCapture: true))
        XCTAssertEqual(reasons, [.manualReset])
        let stoppedCapture = await source.stopCapture()
        XCTAssertTrue(stoppedCapture.samples.isEmpty)
    }

    @MainActor
    func testTransientMissingInputFormatRetriesWithoutLeavingATap() async throws {
        let session = FakeAudioEngineSession()
        let source = AVAudioEngineAudioSource(
            session: session,
            recoveryAttemptCount: 2,
            recoveryRetryDelay: .zero
        )
        try source.prewarm()
        session.queuedFormats = [nil]

        let outcome = await source.resetMicrophone()

        XCTAssertEqual(outcome, .recovered(interruptedCapture: false))
        XCTAssertEqual(session.installCount, 2)
        XCTAssertEqual(session.removeCount, 1)
    }

    @MainActor
    func testFailedRestartReportsFailureAndTheNextResetCanRetry() async throws {
        let session = FakeAudioEngineSession()
        let source = AVAudioEngineAudioSource(
            session: session,
            recoveryAttemptCount: 2,
            recoveryRetryDelay: .zero
        )
        try source.prewarm()
        session.startFailuresRemaining = 2

        let failedOutcome = await source.resetMicrophone()
        XCTAssertEqual(failedOutcome, .failed(interruptedCapture: false))
        XCTAssertFalse(session.isRunning)

        let recoveredOutcome = await source.resetMicrophone()
        XCTAssertEqual(recoveredOutcome, .recovered(interruptedCapture: false))
        XCTAssertTrue(session.isRunning)
    }

    @MainActor
    func testStartCaptureSelfHealsWhenTheEngineStoppedWithoutANotification() throws {
        let session = FakeAudioEngineSession()
        let source = AVAudioEngineAudioSource(session: session)
        try source.prewarm()
        session.isRunning = false

        try source.startCapture()

        XCTAssertEqual(session.installCount, 2)
        XCTAssertEqual(session.removeCount, 1)
        XCTAssertTrue(session.isRunning)
    }

    @MainActor
    func testAutomaticRecoveryCoalescesTwoConfigurationChanges() async throws {
        let session = FakeAudioEngineSession()
        let source = AVAudioEngineAudioSource(
            session: session,
            recoveryAttemptCount: 1,
            recoveryRetryDelay: .zero,
            automaticRecoveryDelay: .zero
        )
        try source.prewarm()

        source.handleConfigurationChange()
        source.handleConfigurationChange()
        await source.waitForPendingRecovery()

        XCTAssertEqual(session.installCount, 2)
        XCTAssertEqual(session.removeCount, 1)
        XCTAssertEqual(session.startCount, 2)
    }

    func testNotificationBurstsCoalesce() {
        var state = MicrophoneRecoveryState()
        XCTAssertTrue(state.schedule())
        XCTAssertFalse(state.schedule())
        state.begin()
        XCTAssertTrue(state.schedule())
    }

    func testRecoveryMarksUnavailableUntilRestartSucceeds() {
        var state = MicrophoneRecoveryState()
        _ = state.schedule()
        state.begin()
        state.removedTap()
        state.failed()
        XCTAssertFalse(state.available)
        XCTAssertFalse(state.tapInstalled)
        state.installedTap()
        state.succeeded()
        XCTAssertTrue(state.available)
        XCTAssertTrue(state.tapInstalled)
    }

    func testManualAndAutomaticRecoveryUseSameStateTransitions() {
        var automatic = MicrophoneRecoveryState()
        var manual = MicrophoneRecoveryState()
        _ = automatic.schedule()
        _ = manual.schedule()
        automatic.begin(); manual.begin()
        automatic.removedTap(); manual.removedTap()
        automatic.installedTap(); manual.installedTap()
        automatic.succeeded(); manual.succeeded()
        XCTAssertEqual(automatic, manual)
    }
}
