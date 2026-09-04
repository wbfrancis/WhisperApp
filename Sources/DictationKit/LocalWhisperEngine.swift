import Foundation
import CWhisper

public enum WhisperProfile: Sendable { case live, file }

public final class TranscriptionCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

private final class WhisperContext {
    let pointer: OpaquePointer
    init(pointer: OpaquePointer) { self.pointer = pointer }
    deinit { whisper_free(pointer) }
}

private final class WhisperWorker: @unchecked Sendable {
    private static let backendLock = NSLock()
    nonisolated(unsafe) private static var backendsLoaded = false
    private let execution = SerialTranscriptionExecutor()
    private let modelPath: String
    private var context: WhisperContext?

    init(modelPath: String) { self.modelPath = modelPath }

    func transcribe(
        samples: [Float], profile: WhisperProfile, token: TranscriptionCancellationToken
    ) async throws -> String {
        try await execution.run { [self] in try run(samples: samples, profile: profile, token: token) }
    }

    private func loadBackendsIfNeeded() throws {
        Self.backendLock.lock(); defer { Self.backendLock.unlock() }
        guard !Self.backendsLoaded else { return }
        let path = ProcessInfo.processInfo.environment["GGML_BACKEND_PATH"] ?? "/opt/homebrew/opt/ggml/libexec"
        ggml_backend_load_all_from_path(path)
        guard ggml_backend_reg_count() > 0 else { throw WhisperError.backendsUnavailable(path) }
        Self.backendsLoaded = true
    }

    private func loadIfNeeded() throws {
        guard context == nil else { return }
        try loadBackendsIfNeeded()
        var parameters = whisper_context_default_params()
        parameters.use_gpu = true
        guard let pointer = whisper_init_from_file_with_params(modelPath, parameters) else {
            throw WhisperError.modelLoadFailed(modelPath)
        }
        context = WhisperContext(pointer: pointer)
    }

    private func run(
        samples: [Float], profile: WhisperProfile, token: TranscriptionCancellationToken
    ) throws -> String {
        guard !samples.isEmpty else { return "" }
        if token.isCancelled { throw WhisperError.cancelled }
        try loadIfNeeded()
        guard let context = context?.pointer else { throw WhisperError.notLoaded }
        var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        parameters.print_progress = false
        parameters.print_realtime = false
        parameters.print_timestamps = false
        parameters.no_timestamps = true
        parameters.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        parameters.no_context = true
        parameters.suppress_blank = true
        parameters.suppress_nst = true
        parameters.temperature = 0
        parameters.temperature_inc = 0
        parameters.single_segment = profile == .live
        parameters.abort_callback = { pointer in
            guard let pointer else { return false }
            return Unmanaged<TranscriptionCancellationToken>.fromOpaque(pointer)
                .takeUnretainedValue().isCancelled
        }
        parameters.abort_callback_user_data = Unmanaged.passUnretained(token).toOpaque()
        let status: Int32 = "en".withCString { language in
            parameters.language = language
            return samples.withUnsafeBufferPointer { buffer in
                whisper_full(context, parameters, buffer.baseAddress, Int32(buffer.count))
            }
        }
        if token.isCancelled { throw WhisperError.cancelled }
        guard status == 0 else { throw WhisperError.transcriptionFailed(status) }
        var text = ""
        for index in 0..<whisper_full_n_segments(context) {
            if let segment = whisper_full_get_segment_text(context, index) {
                text += String(cString: segment)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public final class SerialTranscriptionExecutor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "whisper.resident-worker", qos: .userInitiated)
    public init() {}

    public func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

@MainActor public protocol FileChunkTranscribing: AnyObject {
    func transcribeFileChunk(_ audio: CapturedAudio) async throws -> String
    func cancelFileChunk()
}

@MainActor
public final class LocalWhisperEngine: TranscriptionEngine, FileChunkTranscribing {
    private let worker: WhisperWorker
    private var activeFileToken: TranscriptionCancellationToken?

    public init(modelPath: String) { worker = WhisperWorker(modelPath: modelPath) }

    public static func resident(modelStore: WhisperModelStore = WhisperModelStore()) async throws -> LocalWhisperEngine {
        let url = try await modelStore.ensureAvailable()
        return LocalWhisperEngine(modelPath: url.path)
    }

    public func warmUp() async {
        _ = try? await worker.transcribe(
            samples: [Float](repeating: 0, count: CapturedAudio.sampleRate),
            profile: .live, token: TranscriptionCancellationToken()
        )
    }

    public func transcribe(_ audio: CapturedAudio) async throws -> String {
        try await transcribeRaw(SilenceTrim.trimmingTrailingSilence(audio.samples))
    }

    public func transcribeRaw(_ samples: [Float]) async throws -> String {
        try await worker.transcribe(samples: samples, profile: .live, token: TranscriptionCancellationToken())
    }

    public func transcribeFileChunk(_ audio: CapturedAudio) async throws -> String {
        let token = TranscriptionCancellationToken()
        activeFileToken = token
        defer { if activeFileToken === token { activeFileToken = nil } }
        return try await worker.transcribe(samples: audio.samples, profile: .file, token: token)
    }

    public func cancelFileChunk() { activeFileToken?.cancel() }
}
