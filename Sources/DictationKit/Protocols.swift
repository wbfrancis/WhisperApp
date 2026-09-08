import Foundation

// The four OS boundaries the dictation loop runs against. Each is faked in tests;
// the real adapters land in later tickets (#3 whisper, #4 audio, #5 hotkey, #6 inject).

/// 16kHz mono PCM captured from the mic. `isEmpty` drives the "no audio" path — the
/// prototype found an unfinalized recording yields zero frames.
public struct CapturedAudio: Equatable, Sendable {
    public static let sampleRate = 16_000
    public static let minimumLiveSampleCount = 8_000
    public let samples: [Float]
    public init(samples: [Float]) { self.samples = samples }
    public var isEmpty: Bool { samples.isEmpty }
}

public protocol TextNormalizer: Sendable {
    func normalize(_ text: String) -> String
}

/// Captures microphone audio. Real impl: `AVAudioEngine` (#4).
@MainActor public protocol AudioSource {
    /// Begin capturing. Throws if the mic can't be opened (e.g. no permission).
    func startCapture() throws
    /// Stop capturing and hand back what was captured (possibly empty).
    func stopCapture() async -> CapturedAudio
}

/// Turns captured audio into text. Real impl: local whisper.cpp (#3); the protocol
/// is also the seam a cloud engine drops into later.
@MainActor public protocol TranscriptionEngine {
    func transcribe(_ audio: CapturedAudio) async throws -> String
    /// Run once at launch to hide first-use cost (e.g. Metal shader compile).
    func warmUp() async
}

/// Inserts text at the cursor. Real impl: pasteboard + synthesized ⌘V (#6).
@MainActor public protocol TextInjector {
    /// Insert `text` at the cursor. When `restoringPreviousClipboard` is true, the
    /// prior clipboard contents are put back after the paste; when false, the
    /// dictated text is left on the clipboard.
    func inject(_ text: String, restoringPreviousClipboard: Bool) throws
}

/// Reports activation of the hotkey. Real impl: `CGEventTap` on Right Option (#5).
/// The app layer (#7) connects these to the controller's `activationBegan/Ended`.
@MainActor public protocol HotkeySource: AnyObject {
    var onActivationBegan: (() -> Void)? { get set }
    var onActivationEnded: (() -> Void)? { get set }
    func start() throws
    func stop()
}

/// User-configurable behavior, persisted across restarts by `SettingsStore`.
public enum CueVolume: Float, CaseIterable, Sendable, Equatable, Codable {
    case mute = 0
    case quarter = 0.25
    case half = 0.5
    case threeQuarters = 0.75
    case full = 1

    public var title: String {
        switch self {
        case .mute: return "Mute"
        case .quarter: return "25%"
        case .half: return "50%"
        case .threeQuarters: return "75%"
        case .full: return "100%"
        }
    }
}

public struct Settings: Equatable, Sendable, Codable {
    public enum Mode: String, Sendable, Equatable, Codable {
        /// Hold to talk, release to transcribe+insert.
        case pushToTalk
        /// Tap to start, tap again to stop.
        case toggle
    }

    /// The key that triggers dictation. Honored by the hotkey adapter.
    public var activationKey: ModifierKey
    public var mode: Mode
    public var restoreClipboard: Bool
    public var cueVolume: CueVolume
    public var normalizeLiveDictation: Bool
    public var statusDotColors: StatusDotColors

    public init(
        activationKey: ModifierKey = .rightOption,
        mode: Mode = .pushToTalk,
        restoreClipboard: Bool = true,
        cueVolume: CueVolume = .full,
        normalizeLiveDictation: Bool = true,
        statusDotColors: StatusDotColors = .default
    ) {
        self.activationKey = activationKey
        self.mode = mode
        self.restoreClipboard = restoreClipboard
        self.cueVolume = cueVolume
        self.normalizeLiveDictation = normalizeLiveDictation
        self.statusDotColors = statusDotColors
    }

    private enum CodingKeys: String, CodingKey {
        case activationKey, mode, restoreClipboard, cueVolume, normalizeLiveDictation, statusDotColors
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        activationKey = try values.decode(ModifierKey.self, forKey: .activationKey)
        mode = try values.decode(Mode.self, forKey: .mode)
        restoreClipboard = try values.decode(Bool.self, forKey: .restoreClipboard)
        cueVolume = try values.decodeIfPresent(CueVolume.self, forKey: .cueVolume) ?? .full
        normalizeLiveDictation = try values.decodeIfPresent(
            Bool.self, forKey: .normalizeLiveDictation
        ) ?? true
        statusDotColors = try values.decodeIfPresent(
            StatusDotColors.self, forKey: .statusDotColors
        ) ?? .default
    }
}
