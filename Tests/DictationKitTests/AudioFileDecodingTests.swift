import AVFoundation
import XCTest
@testable import DictationKit

final class AudioFileDecodingTests: XCTestCase {
    func testM4AFixturePlansAndDecodesIncrementally() throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("fixtures/audio/Levels A.m4a")
        let plan = try AudioDecoding.plan(for: url)
        let samples = try AudioDecoding.samples16kMono(fromFile: url, chunk: plan.chunks[0])
        XCTAssertGreaterThan(plan.duration, 0)
        XCTAssertFalse(samples.isEmpty)
    }

    func testStereo48kWAVDownmixesAndResamples() throws {
        let url = temporaryURL(extension: "wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeWave(url: url, sampleRate: 48_000, channels: 2, seconds: 1)
        let plan = try AudioDecoding.plan(for: url)
        let samples = try AudioDecoding.samples16kMono(fromFile: url, chunk: plan.chunks[0])
        XCTAssertEqual(samples.count, 16_000, accuracy: 1_100)
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.01)
    }

    func testCorruptAndEmptyFilesFail() throws {
        let corrupt = temporaryURL(extension: "wav")
        let empty = temporaryURL(extension: "wav")
        defer {
            try? FileManager.default.removeItem(at: corrupt)
            try? FileManager.default.removeItem(at: empty)
        }
        try Data("not audio".utf8).write(to: corrupt)
        XCTAssertThrowsError(try AudioDecoding.plan(for: corrupt))
        try writeWave(url: empty, sampleRate: 16_000, channels: 1, seconds: 0)
        XCTAssertThrowsError(try AudioDecoding.plan(for: empty)) { error in
            XCTAssertEqual(error as? AudioDecoding.FileError, .noAudio)
        }
    }

    func testOnlyM4AAndWAVAreAccepted() {
        XCTAssertThrowsError(try AudioDecoding.plan(for: URL(fileURLWithPath: "/tmp/audio.mp4"))) { error in
            XCTAssertEqual(error as? AudioDecoding.FileError, .unsupportedExtension)
        }
    }

    func testThirtyMinuteBoundaryNeedsNoLargeFixture() {
        XCTAssertTrue(AudioFilePlan.accepts(duration: 1_800))
        XCTAssertFalse(AudioFilePlan.accepts(duration: 1_800.001))
        XCTAssertFalse(AudioFilePlan.accepts(duration: 0))
    }

    private func temporaryURL(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    private func writeWave(url: URL, sampleRate: Double, channels: AVAudioChannelCount, seconds: Double) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        guard frames > 0 else { return }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let pointer = buffer.floatChannelData![channel]
            for index in 0..<Int(frames) {
                pointer[index] = 0.2 * sinf(2 * .pi * 440 * Float(index) / Float(sampleRate))
            }
        }
        try file.write(from: buffer)
    }
}
