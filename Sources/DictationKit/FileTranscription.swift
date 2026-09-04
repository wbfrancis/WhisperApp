import Foundation

public struct AudioFileChunk: Sendable, Equatable {
    public let index: Int
    public let totalCount: Int
    public let startSample: Int
    public let uniqueStartSample: Int
    public let endSample: Int
}

public struct AudioFilePlan: Sendable, Equatable {
    public static let uniqueChunkSeconds = 27
    public static let overlapSeconds = 1
    public static let maximumDuration: TimeInterval = 30 * 60
    public let duration: TimeInterval
    public let chunks: [AudioFileChunk]

    public static func accepts(duration: TimeInterval) -> Bool {
        duration > 0 && duration <= maximumDuration
    }

    public init(duration: TimeInterval) {
        self.duration = duration
        let sampleRate = CapturedAudio.sampleRate
        let totalSamples = Int((duration * Double(sampleRate)).rounded())
        let uniqueSamples = Self.uniqueChunkSeconds * sampleRate
        let overlapSamples = Self.overlapSeconds * sampleRate
        let count = max(1, Int(ceil(Double(totalSamples) / Double(uniqueSamples))))
        chunks = (0..<count).map { index in
            let uniqueStart = index * uniqueSamples
            return AudioFileChunk(
                index: index,
                totalCount: count,
                startSample: max(0, uniqueStart - (index == 0 ? 0 : overlapSamples)),
                uniqueStartSample: uniqueStart,
                endSample: min(totalSamples, (index + 1) * uniqueSamples)
            )
        }
    }
}

public enum TranscriptOverlapMerge {
    public static func merge(_ committed: String, _ next: String) -> String {
        let cleanCommitted = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNext = next.trimmingCharacters(in: .whitespacesAndNewlines)
        let left = cleanCommitted.split(whereSeparator: \.isWhitespace).map(String.init)
        let right = wordRanges(in: cleanNext)
        guard !left.isEmpty else { return cleanNext }
        guard !right.isEmpty else { return cleanCommitted }
        let maximum = min(24, left.count, right.count)
        var duplicateCount = 0
        if maximum > 0 {
            for count in stride(from: maximum, through: 1, by: -1) {
                let suffix = left.suffix(count).map(canonical)
                let prefix = right.prefix(count).map { canonical($0.word) }
                if suffix == prefix { duplicateCount = count; break }
            }
        }
        guard duplicateCount > 0 else { return cleanCommitted + " " + cleanNext }
        let cut = right[duplicateCount - 1].range.upperBound
        let remainder = cleanNext[cut...].drop(while: \.isWhitespace)
        return remainder.isEmpty ? cleanCommitted : cleanCommitted + " " + remainder
    }

    private static func wordRanges(in text: String) -> [(word: String, range: Range<String.Index>)] {
        var result: [(String, Range<String.Index>)] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            guard index < text.endIndex else { break }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
            result.append((String(text[start..<index]), start..<index))
        }
        return result
    }

    private static func canonical(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}

public enum FileTranscriptionState: Sendable, Equatable {
    case idle
    case running(percent: Int)
    case pausedForLiveDictation(percent: Int)
    case failed(String)
    case cancelled
}

public extension FileTranscriptionState {
    var isTerminalFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

public struct FileTranscriptionResult: Sendable, Equatable {
    public let sourceURL: URL
    public let text: String
    public let isPartial: Bool
}

public enum FileResultPresentation {
    public static func stateLabel(isPartial: Bool) -> String { isPartial ? "Partial" : "Complete" }
    public static func suggestedFilename(sourceURL: URL, isPartial: Bool) -> String {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        return "\(base)\(isPartial ? "-partial" : "").txt"
    }
}

@MainActor
public final class FileTranscriptionCoordinator {
    public typealias Decoder = @Sendable (AudioFileChunk) async throws -> CapturedAudio
    public var onStateChange: ((FileTranscriptionState) -> Void)?
    public var onResult: ((FileTranscriptionResult) -> Void)?
    public private(set) var state: FileTranscriptionState = .idle {
        didSet { onStateChange?(state) }
    }
    public var isBusy: Bool { task != nil }

    private let engine: any FileChunkTranscribing
    private let decode: Decoder
    private var task: Task<Void, Never>?
    private var paused = false
    private var userCancelled = false

    public init(engine: any FileChunkTranscribing, decode: @escaping Decoder) {
        self.engine = engine
        self.decode = decode
    }

    @discardableResult
    public func start(sourceURL: URL, plan: AudioFilePlan) -> Bool {
        guard task == nil else { return false }
        paused = false
        userCancelled = false
        state = .running(percent: 0)
        task = Task { [weak self] in await self?.run(sourceURL: sourceURL, plan: plan) }
        return true
    }

    public func pauseForLiveDictation() {
        guard task != nil else { return }
        paused = true
        engine.cancelFileChunk()
        state = .pausedForLiveDictation(percent: currentPercent)
    }

    public func resumeAfterLiveDictation() {
        guard task != nil, !userCancelled else { return }
        paused = false
        state = .running(percent: currentPercent)
    }

    public func cancel() {
        guard task != nil else { return }
        userCancelled = true
        paused = false
        engine.cancelFileChunk()
    }

    public func waitUntilFinished() async {
        await task?.value
    }

    private var completedCount = 0
    private var totalCount = 1
    private var currentPercent: Int { min(99, completedCount * 100 / totalCount) }

    private func run(sourceURL: URL, plan: AudioFilePlan) async {
        completedCount = 0
        totalCount = plan.chunks.count
        var committed = ""
        var index = 0
        while index < plan.chunks.count {
            if userCancelled { break }
            while paused && !userCancelled { try? await Task.sleep(for: .milliseconds(20)) }
            if userCancelled { break }
            do {
                let audio = try await decode(plan.chunks[index])
                let text = try await engine.transcribeFileChunk(audio)
                if userCancelled { break }
                if paused { continue }
                committed = TranscriptOverlapMerge.merge(committed, text)
                index += 1
                completedCount = index
                let percent = index == totalCount ? 100 : currentPercent
                state = .running(percent: percent)
            } catch WhisperError.cancelled {
                if userCancelled { break }
                continue
            } catch {
                state = .failed(String(describing: error))
                finishTask()
                return
            }
        }
        if userCancelled {
            if completedCount > 0 {
                onResult?(FileTranscriptionResult(sourceURL: sourceURL, text: committed, isPartial: true))
            }
            state = .cancelled
        } else {
            onResult?(FileTranscriptionResult(sourceURL: sourceURL, text: committed, isPartial: false))
        }
        finishTask()
    }

    private func finishTask() {
        task = nil
        if case .failed = state { return }
        state = .idle
    }
}
