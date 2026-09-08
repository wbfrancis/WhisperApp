import Foundation

/// A gamma-independent RGB triple in 0...1. Kept AppKit-free so the icon model stays
/// pure and testable; the app maps this onto an `NSColor` at draw time.
public struct IconColor: Equatable, Sendable, Codable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "#" { value.removeFirst() }
        guard value.count == 6, value.allSatisfy(\.isHexDigit),
              let number = UInt32(value, radix: 16) else { return nil }
        self.init(
            Double((number >> 16) & 0xff) / 255,
            Double((number >> 8) & 0xff) / 255,
            Double(number & 0xff) / 255
        )
    }

    public var hex: String {
        func byte(_ value: Double) -> UInt8 {
            UInt8((min(1, max(0, value)) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// The dictation-status palette. Shades are an implementation choice, subject to
    /// visual review — the behavior table only fixes the hues (red/yellow/blue/orange).
    public static let recordingRed = IconColor(0.85, 0.17, 0.15)
    public static let processingYellow = IconColor(0.96, 0.78, 0.13)
    public static let successBlue = IconColor(0.16, 0.50, 0.96)
    public static let failureOrange = IconColor(0.96, 0.53, 0.11)
}

public enum StatusDotKind: String, CaseIterable, Sendable, Codable {
    case recording, processing, success, failure

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

public struct StatusDotColors: Equatable, Sendable, Codable {
    public var recording: IconColor
    public var processing: IconColor
    public var success: IconColor
    public var failure: IconColor

    public static let `default` = StatusDotColors(
        recording: .recordingRed,
        processing: .processingYellow,
        success: .successBlue,
        failure: .failureOrange
    )

    public subscript(kind: StatusDotKind) -> IconColor {
        get {
            switch kind {
            case .recording: recording
            case .processing: processing
            case .success: success
            case .failure: failure
            }
        }
        set {
            switch kind {
            case .recording: recording = newValue
            case .processing: processing = newValue
            case .success: success = newValue
            case .failure: failure = newValue
            }
        }
    }
}

/// What the menu-bar icon should look like at one instant, expressed without AppKit.
///
/// The app renders it as the normal waveform plus a status dot in the bottom-right, drawn
/// in `color` at a prominence of `1 - normalWeight` (0 = fully opaque dot, 1 = no dot). At
/// `normalWeight >= 1` (or `color == nil`) it draws the plain template waveform, so idle
/// stays visible and appearance-adaptive in both light and dark menu bars, and a pulse or
/// the success fade eases the dot out toward that idle look.
public struct IconRenderSpec: Equatable, Sendable {
    /// The status-dot color, or `nil` for the plain normal icon with no dot.
    public let color: IconColor?
    /// How much of the normal (dot-free) appearance shows through, 0...1.
    public let normalWeight: Double

    public init(color: IconColor?, normalWeight: Double) {
        self.color = color
        self.normalWeight = normalWeight
    }

    /// The plain, appearance-adaptive idle waveform.
    public static let normal = IconRenderSpec(color: nil, normalWeight: 1)
}

/// The dictation status the menu-bar icon shows, driven by controller state transitions
/// and end-of-cycle outcomes. Timing is derived from a supplied monotonic clock, so a
/// single frame calculation decides the color at any instant and the whole model is
/// testable without AppKit or real delays.
///
/// The app owns the redraw timer: it renders `frame(at:)` on every tick and stops the
/// timer once `isAnimating(at:)` is false. Because every frame is computed from the
/// current phase's start time, a new recording (or any new phase) instantly invalidates
/// an older result's deadline — there are no per-phase closures that can fire late.
public struct IconPresentationModel: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case normal
        /// Live capture: solid red.
        case recording
        /// Transcription and paste: one continuous yellow blink (1 Hz) across both, crisp
        /// on/off with no fade.
        case processing
        /// Insertion returned successfully: solid blue dot for 1 s, then a 1 s fade to normal.
        case success
        /// Live dictation failed: crisp orange blink (2 Hz) for 5 s, then a short fade out.
        case failure
        /// Short capture or no speech: one brief orange flash that fades out.
        case noSpeech
    }

    // Durations from the approved behavior table. Blinks are crisp on/off (no ramp either
    // way); only the terminal result states — success and failure — fade out at the end.
    static let successHold: TimeInterval = 1
    static let successFade: TimeInterval = 1
    static let failureBlink: TimeInterval = 5
    static let failureFade: TimeInterval = 0.5
    static let noSpeechFlash: TimeInterval = 0.25
    static let processingBlinkHz: Double = 1
    static let failureBlinkHz: Double = 2

    public private(set) var kind: Kind
    private var start: TimeInterval
    private var colors: StatusDotColors

    public init(now: TimeInterval = 0, colors: StatusDotColors = .default) {
        kind = .normal
        start = now
        self.colors = colors
    }

    public mutating func update(colors: StatusDotColors) { self.colors = colors }

    /// Apply a controller state transition.
    public mutating func update(state: DictationController.State, now: TimeInterval) {
        switch state {
        case .recording:
            // A new recording always wins, replacing any in-flight result animation with
            // solid red immediately.
            enter(.recording, now: now)
        case .transcribing, .injecting:
            // Transcription and paste share one continuous pulse; don't restart it when
            // moving from transcribing to injecting.
            if kind != .processing { enter(.processing, now: now) }
        case .idle:
            // `finish` emits the outcome before `.idle`, so the result phase is already
            // set and self-expires on its own timeline; idle must not erase it.
            break
        }
    }

    /// Apply an end-of-cycle outcome.
    public mutating func update(outcome: DictationController.Outcome, now: TimeInterval) {
        switch outcome {
        case .injected:
            enter(.success, now: now)
        case .noAudio:
            enter(.noSpeech, now: now)
        case .failed:
            enter(.failure, now: now)
        case .idle:
            // The initial/no-op outcome produces no result animation.
            break
        }
    }

    private mutating func enter(_ kind: Kind, now: TimeInterval) {
        self.kind = kind
        self.start = now
    }

    /// Timed outcomes retain their start time, but their visible and accessible state
    /// returns to normal at the same boundary as the rendered frame.
    public func visibleKind(at now: TimeInterval) -> Kind {
        switch kind {
        case .success, .failure, .noSpeech:
            return isAnimating(at: now) ? kind : .normal
        default:
            return kind
        }
    }

    /// Whether the icon still changes at or after `now`, so the app keeps its redraw timer
    /// running. Solid phases (normal, recording) don't animate; timed phases stop once
    /// their deadline passes.
    public func isAnimating(at now: TimeInterval) -> Bool {
        let elapsed = now - start
        switch kind {
        case .normal, .recording:
            return false
        case .processing:
            return true
        case .success:
            return elapsed < Self.successHold + Self.successFade
        case .failure:
            return elapsed < Self.failureBlink + Self.failureFade
        case .noSpeech:
            return elapsed < Self.noSpeechFlash
        }
    }

    /// The concrete appearance at `now`.
    public func frame(at now: TimeInterval) -> IconRenderSpec {
        let elapsed = max(0, now - start)
        switch kind {
        case .normal:
            return .normal
        case .recording:
            return IconRenderSpec(color: colors.recording, normalWeight: 0)
        case .processing:
            return blink(elapsed: elapsed, hz: Self.processingBlinkHz, color: colors.processing)
        case .success:
            if elapsed < Self.successHold {
                return IconRenderSpec(color: colors.success, normalWeight: 0)
            }
            let fade = min(1, (elapsed - Self.successHold) / Self.successFade)
            if fade >= 1 { return .normal }
            return IconRenderSpec(color: colors.success, normalWeight: fade)
        case .failure:
            if elapsed < Self.failureBlink {
                return blink(elapsed: elapsed, hz: Self.failureBlinkHz, color: colors.failure)
            }
            let fade = min(1, (elapsed - Self.failureBlink) / Self.failureFade)
            if fade >= 1 { return .normal }
            return IconRenderSpec(color: colors.failure, normalWeight: fade)
        case .noSpeech:
            let fade = min(1, elapsed / Self.noSpeechFlash)
            if fade >= 1 { return .normal }
            return IconRenderSpec(color: colors.failure, normalWeight: fade)
        }
    }

    /// A crisp on/off blink: fully colored for the first half of each cycle, no dot for the
    /// second half. It never ramps in or out — that gradual fade is reserved for the
    /// terminal success and failure states.
    private func blink(elapsed: TimeInterval, hz: Double, color: IconColor) -> IconRenderSpec {
        let cyclePosition = (elapsed * hz).truncatingRemainder(dividingBy: 1)
        return cyclePosition < 0.5 ? IconRenderSpec(color: color, normalWeight: 0) : .normal
    }
}
