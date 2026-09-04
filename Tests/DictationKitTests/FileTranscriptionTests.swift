import XCTest
@testable import DictationKit

@MainActor
private final class FakeFileEngine: FileChunkTranscribing {
    var results: [Result<String, Error>] = []
    private(set) var calls = 0
    private(set) var cancellations = 0

    func transcribeFileChunk(_ audio: CapturedAudio) async throws -> String {
        defer { calls += 1 }
        return try results[calls].get()
    }

    func cancelFileChunk() { cancellations += 1 }
}

@MainActor
final class FileTranscriptionTests: XCTestCase {
    func testPlannerUsesBoundedOverlappingChunks() {
        let plan = AudioFilePlan(duration: 55)
        XCTAssertEqual(plan.chunks.count, 3)
        XCTAssertEqual(plan.chunks[0].startSample, 0)
        XCTAssertEqual(plan.chunks[1].startSample, 26 * 16_000)
        XCTAssertEqual(plan.chunks[1].uniqueStartSample, 27 * 16_000)
        XCTAssertEqual(plan.chunks.last?.endSample, 55 * 16_000)
    }

    func testOverlapMergeKeepsBoundaryPhraseOnce() {
        XCTAssertEqual(
            TranscriptOverlapMerge.merge("alpha beta boundary phrase", "boundary phrase gamma delta"),
            "alpha beta boundary phrase gamma delta"
        )
    }

    func testOverlapMergePreservesInternalNewlinesAndPunctuation() {
        XCTAssertEqual(
            TranscriptOverlapMerge.merge("alpha\nboundary phrase!", "boundary phrase!  gamma\ndelta"),
            "alpha\nboundary phrase! gamma\ndelta"
        )
    }

    func testCoordinatorCommitsProgressOnlyAfterEachSuccessfulChunk() async {
        let engine = FakeFileEngine()
        engine.results = [.success("one"), .success("two")]
        let coordinator = FileTranscriptionCoordinator(engine: engine) { _ in
            CapturedAudio(samples: [Float](repeating: 0.1, count: 8_000))
        }
        var states: [FileTranscriptionState] = []
        var result: FileTranscriptionResult?
        coordinator.onStateChange = { states.append($0) }
        coordinator.onResult = { result = $0 }

        XCTAssertTrue(coordinator.start(sourceURL: URL(fileURLWithPath: "/tmp/two.wav"), plan: AudioFilePlan(duration: 54)))
        await coordinator.waitUntilFinished()

        XCTAssertTrue(states.contains(.running(percent: 50)))
        XCTAssertEqual(states.last, .idle)
        XCTAssertEqual(result?.text, "one two")
        XCTAssertEqual(result?.isPartial, false)
    }

    func testCoordinatorRetriesPreemptedChunkWithoutAdvancingProgress() async {
        let engine = FakeFileEngine()
        engine.results = [.failure(WhisperError.cancelled), .success("one"), .success("two")]
        let coordinator = FileTranscriptionCoordinator(engine: engine) { _ in
            CapturedAudio(samples: [Float](repeating: 0.1, count: 8_000))
        }
        var result: FileTranscriptionResult?
        coordinator.onResult = { result = $0 }

        XCTAssertTrue(coordinator.start(sourceURL: URL(fileURLWithPath: "/tmp/two.wav"), plan: AudioFilePlan(duration: 54)))
        await coordinator.waitUntilFinished()

        XCTAssertEqual(engine.calls, 3)
        XCTAssertEqual(result?.text, "one two")
    }

    func testRepeatedPreemptionRetriesTheSameChunk() async {
        let engine = FakeFileEngine()
        engine.results = [
            .failure(WhisperError.cancelled), .failure(WhisperError.cancelled),
            .success("one"), .success("two"),
        ]
        let coordinator = FileTranscriptionCoordinator(engine: engine) { _ in
            CapturedAudio(samples: [Float](repeating: 0.1, count: 8_000))
        }
        var result: FileTranscriptionResult?
        coordinator.onResult = { result = $0 }
        XCTAssertTrue(coordinator.start(sourceURL: URL(fileURLWithPath: "/tmp/two.wav"), plan: AudioFilePlan(duration: 54)))
        await coordinator.waitUntilFinished()
        XCTAssertEqual(engine.calls, 4)
        XCTAssertEqual(result?.text, "one two")
    }

    func testPauseRequestsCooperativeCancellationAndKeepsPercentage() {
        let engine = FakeFileEngine()
        let coordinator = FileTranscriptionCoordinator(engine: engine) { _ in CapturedAudio(samples: []) }
        XCTAssertTrue(coordinator.start(sourceURL: URL(fileURLWithPath: "/tmp/a.wav"), plan: AudioFilePlan(duration: 27)))
        coordinator.pauseForLiveDictation()
        XCTAssertEqual(coordinator.state, .pausedForLiveDictation(percent: 0))
        XCTAssertEqual(engine.cancellations, 1)
        coordinator.cancel()
    }

    func testDecodeFailureEndsJobWithoutResult() async {
        let engine = FakeFileEngine()
        let coordinator = FileTranscriptionCoordinator(engine: engine) { _ in throw TestError() }
        var result: FileTranscriptionResult?
        coordinator.onResult = { result = $0 }
        XCTAssertTrue(coordinator.start(sourceURL: URL(fileURLWithPath: "/tmp/a.wav"), plan: AudioFilePlan(duration: 27)))
        await coordinator.waitUntilFinished()
        XCTAssertNil(result)
        if case .failed = coordinator.state {} else { XCTFail("expected failure") }
    }

    func testWhisperFailureEndsJobWithoutResult() async {
        let engine = FakeFileEngine()
        engine.results = [.failure(TestError())]
        let coordinator = FileTranscriptionCoordinator(engine: engine) { _ in CapturedAudio(samples: [0.1]) }
        var result: FileTranscriptionResult?
        coordinator.onResult = { result = $0 }
        XCTAssertTrue(coordinator.start(sourceURL: URL(fileURLWithPath: "/tmp/a.wav"), plan: AudioFilePlan(duration: 27)))
        await coordinator.waitUntilFinished()
        XCTAssertNil(result)
        if case .failed = coordinator.state {} else { XCTFail("expected failure") }
    }

    func testSecondFileRequestIsRejectedWhileBusy() {
        let engine = FakeFileEngine()
        let coordinator = FileTranscriptionCoordinator(engine: engine) { _ in CapturedAudio(samples: []) }
        XCTAssertTrue(coordinator.start(sourceURL: URL(fileURLWithPath: "/tmp/a.wav"), plan: AudioFilePlan(duration: 27)))
        XCTAssertFalse(coordinator.start(sourceURL: URL(fileURLWithPath: "/tmp/b.wav"), plan: AudioFilePlan(duration: 27)))
        coordinator.cancel()
    }

    func testCancelBeforeFirstCommitProducesNoEditorResult() async {
        let engine = FakeFileEngine()
        engine.results = [.failure(WhisperError.cancelled)]
        let coordinator = FileTranscriptionCoordinator(engine: engine) { _ in CapturedAudio(samples: []) }
        var result: FileTranscriptionResult?
        coordinator.onResult = { result = $0 }
        XCTAssertTrue(coordinator.start(sourceURL: URL(fileURLWithPath: "/tmp/a.wav"), plan: AudioFilePlan(duration: 27)))
        coordinator.cancel()
        await coordinator.waitUntilFinished()
        XCTAssertNil(result)
    }
}
