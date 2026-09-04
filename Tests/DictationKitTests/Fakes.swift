import Foundation
@testable import DictationKit

struct TestError: Error, Equatable {}

@MainActor
final class FakeAudioSource: AudioSource {
    var toReturn = CapturedAudio(samples: [Float](repeating: 0.1, count: 8_000))
    var startError: Error?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func startCapture() throws {
        startCount += 1
        if let startError { throw startError }
    }

    func stopCapture() async -> CapturedAudio {
        stopCount += 1
        return toReturn
    }
}

struct FakeTextNormalizer: TextNormalizer {
    let result: String
    func normalize(_ text: String) -> String { result }
}

@MainActor
final class FakeTranscriptionEngine: TranscriptionEngine {
    var result = "hello world"
    var error: Error?
    private(set) var warmUpCount = 0
    private(set) var transcribeCount = 0
    private(set) var lastAudio: CapturedAudio?

    func transcribe(_ audio: CapturedAudio) async throws -> String {
        transcribeCount += 1
        lastAudio = audio
        if let error { throw error }
        return result
    }

    func warmUp() async {
        warmUpCount += 1
    }
}

@MainActor
final class FakeHotkeySource: HotkeySource {
    var onActivationBegan: (() -> Void)?
    var onActivationEnded: (() -> Void)?
    private(set) var started = false

    func start() throws { started = true }
    func stop() { started = false }

    // Test drivers simulating the key going down/up.
    func pressDown() { onActivationBegan?() }
    func releaseUp() { onActivationEnded?() }
}

@MainActor
final class FakeTextInjector: TextInjector {
    /// Simulated system clipboard.
    var clipboard: String?
    var injectError: Error?
    private(set) var injected: [String] = []

    func inject(_ text: String, restoringPreviousClipboard: Bool) throws {
        if let injectError { throw injectError }
        injected.append(text)
        let previous = clipboard
        clipboard = text
        if restoringPreviousClipboard {
            clipboard = previous
        }
    }
}
