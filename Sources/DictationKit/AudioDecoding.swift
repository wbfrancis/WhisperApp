import AVFoundation

/// Decodes an audio file to the 16kHz mono float samples the engine consumes — the file
/// counterpart to the live mic path, used by the eval harness to feed fixtures through the
/// exact same resampling the microphone uses.
public enum AudioDecoding {
    public enum FileError: Error, Equatable, LocalizedError {
        case unsupportedExtension
        case noAudio
        case tooLong
        case corrupt

        public var errorDescription: String? {
            switch self {
            case .unsupportedExtension: return "choose a local .m4a or .wav recording"
            case .noAudio: return "the file contains no audio"
            case .tooLong: return "the recording is longer than 30 minutes"
            case .corrupt: return "the audio file is corrupt or unreadable"
            }
        }
    }

    public static func plan(for url: URL) throws -> AudioFilePlan {
        guard ["m4a", "wav"].contains(url.pathExtension.lowercased()) else {
            throw FileError.unsupportedExtension
        }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { throw FileError.corrupt }
        guard file.length > 0, file.processingFormat.sampleRate > 0 else { throw FileError.noAudio }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration <= AudioFilePlan.maximumDuration else { throw FileError.tooLong }
        return AudioFilePlan(duration: duration)
    }

    public static func samples16kMono(fromFile url: URL, chunk: AudioFileChunk) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sourceRate = format.sampleRate
        guard sourceRate > 0 else { throw FileError.noAudio }
        let startFrame = AVAudioFramePosition(Double(chunk.startSample) * sourceRate / 16_000)
        let endFrame = AVAudioFramePosition(Double(chunk.endSample) * sourceRate / 16_000)
        let count = max(0, min(file.length, endFrame) - min(file.length, startFrame))
        guard count > 0 else { throw FileError.noAudio }
        file.framePosition = min(file.length, startFrame)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(count)
        ) else { throw AudioCaptureError.unsupportedFormat }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
        guard let resampler = AudioResampler(from: format) else {
            throw AudioCaptureError.unsupportedFormat
        }
        return resampler.resample(buffer)
    }

    public static func samples16kMono(fromFile url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw AudioCaptureError.unsupportedFormat
        }
        try file.read(into: buffer)
        guard let resampler = AudioResampler(from: format) else {
            throw AudioCaptureError.unsupportedFormat
        }
        return resampler.resample(buffer)
    }
}
