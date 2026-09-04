import AppKit

/// One main-actor timer renders the current phase from a monotonic clock. It never
/// captures a result deadline, so old ticks cannot override a newer recording.
@MainActor
public final class MenuBarIconAnimator {
    private var model: IconPresentationModel
    private let clock: () -> TimeInterval
    private let draw: (IconRenderSpec, String) -> Void
    private var timer: Timer?
    private var stopped = false
    var isTimerRunning: Bool { timer != nil }

    public convenience init(
        button: NSStatusBarButton,
        renderer: IconRenderer,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.init(clock: clock) { [weak button] frame, label in
            guard let button else { return }
            button.image = renderer.image(for: frame, appearance: button.effectiveAppearance)
            // Label the button, not a cached image that is replaced on each frame.
            // Change accessibility properties only when the semantic phase changes.
            if button.toolTip != label {
                button.toolTip = label
                button.setAccessibilityLabel(label)
            }
        }
    }

    /// Tests drive the same timer/model path without creating a status item or showing UI.
    init(clock: @escaping () -> TimeInterval,
         draw: @escaping (IconRenderSpec, String) -> Void) {
        self.clock = clock
        self.draw = draw
        self.model = IconPresentationModel(now: clock())
        tick()
    }

    public func update(state: DictationController.State) {
        guard !stopped else { return }
        model.update(state: state, now: clock())
        refresh()
    }

    public func update(outcome: DictationController.Outcome) {
        guard !stopped else { return }
        model.update(outcome: outcome, now: clock())
        refresh()
    }

    private func refresh() {
        tick()
        if model.isAnimating(at: clock()) { startTimer() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        for mode in [RunLoop.Mode.common, .eventTracking, .modalPanel] {
            RunLoop.main.add(timer, forMode: mode)
        }
        self.timer = timer
    }

    func tick() {
        guard !stopped else { return }
        let now = clock()
        draw(model.frame(at: now), Self.accessibilityLabel(model.visibleKind(at: now)))
        if !model.isAnimating(at: now) { invalidateTimer() }
    }

    private static func accessibilityLabel(_ kind: IconPresentationModel.Kind) -> String {
        switch kind {
        case .normal: return "Dictation"
        case .recording: return "Dictation — recording"
        case .processing: return "Dictation — transcribing and inserting"
        case .success: return "Dictation — inserted"
        case .failure: return "Dictation — failed"
        case .noSpeech: return "Dictation — no speech"
        }
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Called at application termination; any already queued tick becomes a no-op. The
    /// animator lives for the app's lifetime, so this — not a deinit — owns timer teardown
    /// (a nonisolated deinit can't touch the main-actor `Timer` under Swift 6).
    public func stop() {
        stopped = true
        invalidateTimer()
    }
}
