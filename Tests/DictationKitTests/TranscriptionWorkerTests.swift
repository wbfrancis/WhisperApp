import XCTest
@testable import DictationKit

final class TranscriptionWorkerTests: XCTestCase {
    func testCancellationTokenCanBeChangedAcrossThreads() {
        let token = TranscriptionCancellationToken()
        XCTAssertFalse(token.isCancelled)
        DispatchQueue.global().sync { token.cancel() }
        XCTAssertTrue(token.isCancelled)
    }

    func testSerialExecutorNeverRunsTwoCallsTogether() async throws {
        let executor = SerialTranscriptionExecutor()
        let lock = NSLock()
        let tracker = ConcurrencyTracker()
        async let first: Int = executor.run {
            lock.lock(); tracker.active += 1; tracker.maximum = max(tracker.maximum, tracker.active); lock.unlock()
            Thread.sleep(forTimeInterval: 0.04)
            lock.lock(); tracker.active -= 1; lock.unlock()
            return 1
        }
        async let second: Int = executor.run {
            lock.lock(); tracker.active += 1; tracker.maximum = max(tracker.maximum, tracker.active); lock.unlock()
            Thread.sleep(forTimeInterval: 0.04)
            lock.lock(); tracker.active -= 1; lock.unlock()
            return 2
        }
        _ = try await (first, second)
        XCTAssertEqual(tracker.maximum, 1)
    }

    @MainActor
    func testBlockingWorkerDoesNotBlockMainActor() async {
        let executor = SerialTranscriptionExecutor()
        let started = expectation(description: "worker started")
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            try? await executor.run {
                started.fulfill()
                release.wait()
                return 0
            }
        }
        await fulfillment(of: [started], timeout: 1)
        var mainActorRan = false
        mainActorRan = true
        XCTAssertTrue(mainActorRan)
        release.signal()
        _ = await task.value
    }
}

private final class ConcurrencyTracker: @unchecked Sendable {
    var active = 0
    var maximum = 0
}
