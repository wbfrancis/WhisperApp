/// A subtle audio cue for a dictation transition.
public enum DictationSound: Sendable, Equatable {
    /// Recording started — played when the key goes down.
    case start
    /// Recording ended — played when the key is released.
    case stop
}

/// Pure mapping from dictation state to the menu-bar sound cues, kept out of the app layer
/// so the sound choices are testable without AppKit. It marks the recording transitions
/// only; the icon's live-dictation colors are driven separately by `IconPresentationModel`.
public enum MenuBarPresentation {
    /// The sound (if any) to play on a state transition: a start cue when recording begins,
    /// a stop cue when it ends. Other transitions are silent.
    public static func sound(
        from old: DictationController.State,
        to new: DictationController.State
    ) -> DictationSound? {
        if old != .recording, new == .recording { return .start }
        if old == .recording, new != .recording { return .stop }
        return nil
    }
}

/// Tracks the previous state so the app doesn't have to pair transitions itself. Each
/// `advance(to:)` returns the sound for the step taken to reach it, which keeps the
/// transition rules testable without AppKit.
public struct MenuBarPresenter {
    private var lastState: DictationController.State

    public init(initial: DictationController.State = .idle) {
        self.lastState = initial
    }

    public mutating func advance(
        to state: DictationController.State
    ) -> DictationSound? {
        let sound = MenuBarPresentation.sound(from: lastState, to: state)
        lastState = state
        return sound
    }
}

public struct StandardEditCommand: Sendable, Equatable {
    public let title: String
    public let selectorName: String
    public let key: String

    public static let all: [StandardEditCommand] = [
        .init(title: "Undo", selectorName: "undo:", key: "z"),
        .init(title: "Redo", selectorName: "redo:", key: "Z"),
        .init(title: "Cut", selectorName: "cut:", key: "x"),
        .init(title: "Copy", selectorName: "copy:", key: "c"),
        .init(title: "Paste", selectorName: "paste:", key: "v"),
        .init(title: "Select All", selectorName: "selectAll:", key: "a"),
    ]
}

public enum FileMenuPresentation {
    public static func status(for state: FileTranscriptionState) -> String? {
        switch state {
        case .idle: return nil
        case .running(let percent): return "transcribing file — \(percent)%"
        case .pausedForLiveDictation(let percent): return "paused for live dictation — \(percent)%"
        case .failed(let reason): return "file transcription failed — \(reason)"
        case .cancelled: return "file transcription canceled"
        }
    }
}

public enum SoundVolumePresentation {
    public static func amplitudes(for volume: CueVolume) -> (start: Float, stop: Float) {
        (volume.rawValue, volume.rawValue)
    }
}
