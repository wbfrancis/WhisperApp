import XCTest
import AVFoundation
@testable import DictationKit

/// Real end-to-end check of the in-process whisper engine. Skipped unless the model is
/// present, so CI without the ~547MB model stays green; run locally with the model at
/// `prototype/models/` or `WHISPER_MODEL=/path/to/model.bin`.
@MainActor
final class LocalWhisperEngineIntegrationTests: XCTestCase {

    func testTranscribesRealSpeech() async throws {
        let model = try modelPathOrSkip()
        let samples = try synthesizeSpeechSamples("The quick brown fox jumps over the lazy dog")

        let engine = LocalWhisperEngine(modelPath: model)
        await engine.warmUp()
        let text = try await engine.transcribe(CapturedAudio(samples: samples)).lowercased()

        XCTAssertFalse(text.isEmpty, "expected a non-empty transcript")
        XCTAssertTrue(text.contains("fox") || text.contains("quick"),
                      "transcript didn't contain expected words: \(text)")
    }

    func testEmptyAudioProducesNoText() async throws {
        let model = try modelPathOrSkip()
        let engine = LocalWhisperEngine(modelPath: model)
        let text = try await engine.transcribe(CapturedAudio(samples: [Float](repeating: 0, count: 16_000)))
        XCTAssertTrue(text.isEmpty || text.count < 30, "silence should not yield real words: \(text)")
    }

    func testEngineReturnsRawSpokenTimeWithoutNormalization() async throws {
        let model = try modelPathOrSkip()
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("fixtures/audio/Levels A.m4a")
        let samples = try AudioDecoding.samples16kMono(fromFile: fixture)
        let engine = LocalWhisperEngine(modelPath: model)

        let text = try await engine.transcribeRaw(samples).lowercased()

        XCTAssertFalse(text.contains("3:00"), "engine output must stay raw: \(text)")
        XCTAssertTrue(text.contains("o'clock"), "expected fixture's spoken clock form: \(text)")
    }

    // MARK: - Helpers

    private func modelPathOrSkip() throws -> String {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["WHISPER_MODEL"], fm.fileExists(atPath: env) {
            return env
        }
        let proto = fm.currentDirectoryPath + "/prototype/models/ggml-large-v3-turbo-q5_0.bin"
        if fm.fileExists(atPath: proto) { return proto }
        throw XCTSkip("whisper model not present; set WHISPER_MODEL to run this integration test")
    }

    /// Render a phrase to 16kHz mono float samples via `say` + `afconvert`.
    private func synthesizeSpeechSamples(_ phrase: String) throws -> [Float] {
        let tmp = FileManager.default.temporaryDirectory
        let aiff = tmp.appendingPathComponent(UUID().uuidString + ".aiff")
        let wav = tmp.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: aiff); try? FileManager.default.removeItem(at: wav) }

        try run("/usr/bin/say", ["-v", "Samantha", "-o", aiff.path, phrase])
        try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEF32@16000", "-c", "1", aiff.path, wav.path])

        let file = try AVAudioFile(forReading: wav)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            struct FixtureError: Error {}
            throw FixtureError()
        }
        try file.read(into: buffer)
        let count = Int(buffer.frameLength)
        let ptr = buffer.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }

    private func run(_ launchPath: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "\(launchPath) failed")
    }
}
