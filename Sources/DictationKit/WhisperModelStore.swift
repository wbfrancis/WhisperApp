import Foundation

public enum WhisperError: Error, Equatable {
    case modelLoadFailed(String)
    case notLoaded
    case transcriptionFailed(Int32)
    case cancelled
    case downloadFailed(Int)
    /// ggml's compute backend plugins didn't load from the given path — a config error
    /// caught before whisper.cpp would otherwise abort the process.
    case backendsUnavailable(String)
}

/// Locates the whisper model on disk and downloads it on first run. The model is the
/// quantized large-v3-turbo (~547MB), kept out of the app bundle per the design.
public struct WhisperModelStore: Sendable {
    public static let fileName = "ggml-large-v3-turbo-q5_0.bin"
    public static let downloadURL = URL(
        string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
    )!

    public let directory: URL

    /// Defaults to `~/Library/Application Support/whisper/models`.
    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = appSupport.appendingPathComponent("whisper/models", isDirectory: true)
        }
    }

    public var modelURL: URL { directory.appendingPathComponent(Self.fileName) }

    public var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    /// Return the local model URL, downloading it first if it isn't present yet.
    public func ensureAvailable() async throws -> URL {
        if isDownloaded { return modelURL }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (tmp, response) = try await URLSession.shared.download(from: Self.downloadURL)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else { throw WhisperError.downloadFailed(code) }
        try? FileManager.default.removeItem(at: modelURL)
        try FileManager.default.moveItem(at: tmp, to: modelURL)
        return modelURL
    }
}
