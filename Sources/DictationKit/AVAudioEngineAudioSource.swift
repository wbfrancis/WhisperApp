import AVFoundation

public enum AudioCaptureError: Error, Equatable {
    /// The mic's hardware format can't be converted to the 16kHz mono the engine needs.
    case unsupportedFormat
}

public enum MicrophoneRecoveryReason: Sendable, Equatable {
    case deviceChanged
    case manualReset
}

public enum MicrophoneRecoveryOutcome: Sendable, Equatable {
    case recovered(interruptedCapture: Bool)
    case failed(interruptedCapture: Bool)
    case alreadyInProgress
}

@MainActor
public final class MicrophoneResetCoordinator {
    public var onStatus: ((String) -> Void)?

    private let reset: () async -> MicrophoneRecoveryOutcome

    public init(reset: @escaping () async -> MicrophoneRecoveryOutcome) {
        self.reset = reset
    }

    public func performReset() async {
        onStatus?("resetting microphone…")
        let outcome = await reset()
        switch outcome {
        case .recovered(let interruptedCapture):
            onStatus?(interruptedCapture ? "microphone reset — try again" : "microphone reset")
        case .failed:
            onStatus?("microphone reset failed — try again")
        case .alreadyInProgress:
            onStatus?("microphone recovery already in progress")
        }
    }
}

public struct MicrophoneRecoveryState: Sendable, Equatable {
    public private(set) var recoveryScheduled = false
    public private(set) var available = false
    public private(set) var tapInstalled = false

    public init() {}
    public mutating func schedule() -> Bool {
        guard !recoveryScheduled else { return false }
        recoveryScheduled = true
        return true
    }
    public mutating func begin() { recoveryScheduled = false; available = false }
    public mutating func removedTap() { tapInstalled = false }
    public mutating func installedTap() { tapInstalled = true }
    public mutating func succeeded() { available = true }
    public mutating func failed() { available = false }
}

/// A tiny thread-safe boolean the realtime tap reads to know when to collect samples.
/// Lock-guarded and `@unchecked Sendable` so it can cross into the tap closure.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return on
    }

    func set(_ newValue: Bool) {
        lock.lock(); on = newValue; lock.unlock()
    }
}

/// Thread-safe accumulator for captured samples. The mic tap fires on a realtime audio
/// thread, so appends are lock-guarded and the class is `@unchecked Sendable` to cross
/// into the tap closure.
final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ new: [Float]) {
        lock.lock()
        samples.append(contentsOf: new)
        lock.unlock()
    }

    /// Return everything captured so far and reset for the next utterance.
    func drain() -> [Float] {
        lock.lock()
        defer { samples.removeAll(); lock.unlock() }
        return samples
    }
}

/// Resamples mic buffers (any hardware rate, mono or stereo) to 16kHz mono float via one
/// persistent `AVAudioConverter`. Pulled out of the engine so the conversion — the part
/// that must be right (rate, channel downmix, duration) — is unit-tested with synthetic
/// buffers, no microphone. `@unchecked Sendable`: the converter is touched only from the
/// single audio thread once installed (or one test thread), never concurrently.
final class AudioResampler: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let source: AVAudioFormat
    private let target: AVAudioFormat

    init?(from source: AVAudioFormat, to target: AVAudioFormat = AVAudioEngineAudioSource.whisperFormat) {
        guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
        self.converter = converter
        self.source = source
        self.target = target
    }

    /// Convert one input buffer to 16kHz mono samples. Returns `[]` if nothing converted.
    func resample(_ input: AVAudioPCMBuffer) -> [Float] {
        let ratio = target.sampleRate / source.sampleRate
        // Output capacity = input frames scaled by the rate ratio, plus headroom for the
        // resampling filter's edge frames, which can push the count slightly past the ratio.
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil,
              output.frameLength > 0, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

@MainActor
protocol AudioEngineSession: AnyObject {
    var configurationChangeObject: AnyObject { get }
    var isRunning: Bool { get }
    var inputFormat: AVAudioFormat? { get }
    func installTap(
        format: AVAudioFormat,
        block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    )
    func removeTap()
    func prepare()
    func start() throws
    func stop()
    func reset()
}

@MainActor
private final class SystemAudioEngineSession: AudioEngineSession {
    private let engine = AVAudioEngine()

    var configurationChangeObject: AnyObject { engine }
    var isRunning: Bool { engine.isRunning }
    var inputFormat: AVAudioFormat? {
        let format = engine.inputNode.outputFormat(forBus: 0)
        return format.sampleRate > 0 && format.channelCount > 0 ? format : nil
    }

    func installTap(
        format: AVAudioFormat,
        block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        engine.inputNode.installTap(
            onBus: 0, bufferSize: 4096, format: format, block: block
        )
    }

    func removeTap() { engine.inputNode.removeTap(onBus: 0) }
    func prepare() { engine.prepare() }
    func start() throws { try engine.start() }
    func stop() { engine.stop() }
    func reset() { engine.reset() }
}

/// `AudioSource` over `AVAudioEngine`. Taps the mic, resamples to 16kHz mono, and hands
/// the samples over on stop. Samples are accumulated in memory as `[Float]`, so there's no
/// WAV header to finalize — the prototype's zero-length-file bug can't recur; an empty
/// capture is simply an empty sample array, which drives the controller's "no audio" path.
///
/// The engine is started once and kept running (see `prewarm`), and each utterance just
/// toggles collection on and off. Starting the engine cold on every key-down added enough
/// latency to clip the first word, so the mic is held hot instead. The cost is that the
/// mic stays active — and macOS shows its in-use indicator — for the whole session.
@MainActor
public final class AVAudioEngineAudioSource: AudioSource {
    /// 16kHz mono float — the format whisper.cpp consumes; captured audio is resampled to
    /// it. `nonisolated(unsafe)`: `AVAudioFormat` isn't `Sendable`, but an instance is
    /// immutable once built, so sharing this one read-only value across threads is safe.
    nonisolated(unsafe) public static let whisperFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    private let session: any AudioEngineSession
    private let buffer = SampleBuffer()
    private let collecting = Flag()
    private let recoveryAttemptCount: Int
    private let recoveryRetryDelay: Duration
    private let automaticRecoveryDelay: Duration
    private var running = false
    private var tapInstalled = false
    private var recoveryTask: Task<Void, Never>?
    private var recoveryInProgress = false
    nonisolated(unsafe) private var notificationObserver: NSObjectProtocol?
    public var onCaptureInvalidated: ((MicrophoneRecoveryReason) -> Void)?

    public convenience init() {
        self.init(session: SystemAudioEngineSession())
    }

    init(
        session: any AudioEngineSession,
        recoveryAttemptCount: Int = 20,
        recoveryRetryDelay: Duration = .milliseconds(100),
        automaticRecoveryDelay: Duration = .milliseconds(150)
    ) {
        self.session = session
        self.recoveryAttemptCount = recoveryAttemptCount
        self.recoveryRetryDelay = recoveryRetryDelay
        self.automaticRecoveryDelay = automaticRecoveryDelay
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: session.configurationChangeObject,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleConfigurationChange() }
        }
    }

    deinit {
        if let notificationObserver { NotificationCenter.default.removeObserver(notificationObserver) }
    }

    /// Start the mic engine ahead of first use so the first key-down has no cold-start
    /// latency. Safe to call at launch; the first real capture reuses the hot engine.
    public func prewarm() throws {
        try ensureRunning()
    }

    public func startCapture() throws {
        try ensureRunning()   // no-op once hot; retries if a prior prewarm was blocked
        _ = buffer.drain()    // discard anything left from a prior capture
        collecting.set(true)
    }

    public func stopCapture() async -> CapturedAudio {
        collecting.set(false)
        return CapturedAudio(samples: buffer.drain())
    }

    public func resetMicrophone() async -> MicrophoneRecoveryOutcome {
        guard !recoveryInProgress, recoveryTask == nil else { return .alreadyInProgress }
        recoveryInProgress = true
        defer { recoveryInProgress = false }
        let interruptedCapture = collecting.value
        if interruptedCapture { onCaptureInvalidated?(.manualReset) }
        let recovered = await recoverWithRetry()
        return recovered
            ? .recovered(interruptedCapture: interruptedCapture)
            : .failed(interruptedCapture: interruptedCapture)
    }

    private func scheduleAutomaticRecovery() {
        guard recoveryTask == nil, !recoveryInProgress else { return }
        let interruptedCapture = collecting.value
        collecting.set(false)
        _ = buffer.drain()
        running = false
        if interruptedCapture { onCaptureInvalidated?(.deviceChanged) }
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.automaticRecoveryDelay)
            guard !Task.isCancelled else { return }
            _ = await self.recoverWithRetry()
            self.recoveryTask = nil
        }
    }

    func handleConfigurationChange() {
        scheduleAutomaticRecovery()
    }

    func waitForPendingRecovery() async {
        await recoveryTask?.value
    }

    private func recoverWithRetry() async -> Bool {
        tearDownEngine()
        for attempt in 0..<recoveryAttemptCount {
            do {
                try installAndStart()
                return true
            } catch {
                if attempt < recoveryAttemptCount - 1 {
                    try? await Task.sleep(for: recoveryRetryDelay)
                }
            }
        }
        return false
    }

    /// Install the tap and start the engine once; keep both hot for the session. Idempotent.
    private func ensureRunning() throws {
        guard recoveryTask == nil, !recoveryInProgress else {
            throw AudioCaptureError.unsupportedFormat
        }
        if running, session.isRunning { return }
        if running || tapInstalled { tearDownEngine() }
        try installAndStart()
    }

    private func installAndStart() throws {

        guard let inputFormat = session.inputFormat else {
            throw AudioCaptureError.unsupportedFormat
        }
        guard let resampler = AudioResampler(from: inputFormat) else {
            throw AudioCaptureError.unsupportedFormat
        }

        // The tap fires on the realtime audio thread, so the block is `@Sendable` (never
        // main-actor isolated) and captures only Sendable values — the collection gate, the
        // resampler, and the sample sink — never `self`.
        let sink = buffer
        let gate = collecting
        let block: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { pcm, _ in
            guard gate.value else { return }   // drop buffers outside an utterance
            let samples = resampler.resample(pcm)
            if !samples.isEmpty { sink.append(samples) }
        }
        session.installTap(format: inputFormat, block: block)
        tapInstalled = true

        session.prepare()
        do {
            try session.start()  // throws if the mic can't be opened (e.g. no permission)
        } catch {
            // Start failed, so remove the tap we just installed; otherwise a retry would
            // hit AVAudioEngine's one-tap-per-bus limit and trap.
            session.removeTap()
            tapInstalled = false
            throw error
        }
        running = true
    }

    private func tearDownEngine() {
        collecting.set(false)
        _ = buffer.drain()
        running = false
        if tapInstalled {
            session.removeTap()
            tapInstalled = false
        }
        session.stop()
        session.reset()
    }
}
