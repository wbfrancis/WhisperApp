import AppKit
import AVFoundation
import ApplicationServices
import DictationKit
import UniformTypeIdentifiers

@MainActor
func installStandardEditMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit whisper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    let editItem = NSMenuItem()
    main.addItem(editItem)
    let editMenu = NSMenu(title: "Edit")
    for command in StandardEditCommand.all {
        editMenu.addItem(
            withTitle: command.title,
            action: NSSelectorFromString(command.selectorName),
            keyEquivalent: command.key
        )
    }
    editItem.submenu = editMenu
    NSApp.mainMenu = main
}

/// Echo a lifecycle line to the terminal so behavior is visible when run via `swift run`
/// (the menu status line isn't). Prefixed for easy grepping.
func log(_ message: String) {
    FileHandle.standardError.write(Data("[whisper] \(message)\n".utf8))
}

/// Real permission probes for the menu-bar agent. The decisions about what's missing and
/// what to say live in the tested `PermissionsPresentation`; this just reads system state.
@MainActor
final class SystemPermissions {
    var microphone: AuthStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    func state() -> PermissionsState {
        PermissionsState(microphone: microphone, accessibilityGranted: accessibilityGranted)
    }

    /// Show the one-time system microphone prompt (no-op if already decided).
    func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Ask the system to add this app to the Accessibility list. Non-blocking: it shows
    /// the standard "…would like to control this computer" dialog (with an Open System
    /// Settings button) and returns right away, so it never stalls launch the way a modal
    /// on the boot path does. No-op once granted.
    func promptAccessibility() {
        // The literal value of `kAXTrustedCheckOptionPrompt`; used directly because that
        // imported global isn't concurrency-safe to reference under Swift 6.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}

// The menu-bar agent. Assembles the real adapters (mic capture, local whisper, pasteboard
// injection, the activation hotkey) into the DictationController, so holding the activation
// key, speaking, and releasing pastes text at the cursor in any app. The icon reflects
// state, subtle start/stop sounds play on the transitions, and the menu configures the
// activation key, mode, and clipboard-restore — all persisted across restarts.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// A push-to-talk key event, funnelled through one ordered stream (below) so a fast
    /// tap can never deliver `ended` before `began`.
    private enum Activation { case began, ended }

    private let brand = "whisper"
    private var statusItem: NSStatusItem?
    private var statusLineItem: NSMenuItem?

    // Config menu items, kept so their checkmarks can be refreshed after a change.
    private var keyItems: [NSMenuItem] = []
    private var modeItems: [NSMenuItem] = []
    private var restoreItem: NSMenuItem?
    private var normalizeLiveItem: NSMenuItem?
    private var cueVolumeItems: [NSMenuItem] = []
    private var transcribeFileItem: NSMenuItem?
    private var cancelFileItem: NSMenuItem?

    // Kept alive for the process lifetime: the controller drives the loop, the hotkey feeds
    // it activations, the continuation carries key events, and the sounds are reused.
    private var controller: DictationController?
    private var audioSource: AVAudioEngineAudioSource?
    private var microphoneResetCoordinator: MicrophoneResetCoordinator?
    private var whisperEngine: LocalWhisperEngine?
    private var fileCoordinator: FileTranscriptionCoordinator?
    private var resultWindows: [FileResultWindowController] = []
    private var hotkey: CGEventTapHotkeySource?
    private var accessibilityRetry: Task<Void, Never>?
    private var activations: AsyncStream<Activation>.Continuation?
    private var presenter = MenuBarPresenter()
    private var iconAnimator: MenuBarIconAnimator?
    private var routingInjector: RoutingTextInjector?
    private let startSound = AppDelegate.bundledSound(named: "recording-start")
    private let stopSound = AppDelegate.bundledSound(named: "recording-stop")

    private let settingsStore = SettingsStore()
    private var settings = Settings()
    private let permissions = SystemPermissions()
    private let feedbackLog = FeedbackLog()

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = settingsStore.load()  // sync + fast; ready before assembly builds anything
        installStandardEditMenu()
        applyCueVolume()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item  // set before setIcon: it reads statusItem?.button, so the idle icon shows at launch
        setIcon()

        let menu = NSMenu()
        let statusLine = NSMenuItem(title: "\(brand) — starting…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        buildConfigItems(into: menu)
        menu.addItem(.separator())
        let transcribeFile = NSMenuItem(
            title: "Transcribe Audio File…", action: #selector(transcribeAudioFile), keyEquivalent: ""
        )
        transcribeFile.target = self
        menu.addItem(transcribeFile)
        transcribeFileItem = transcribeFile
        let cancelFile = NSMenuItem(
            title: "Cancel File Transcription", action: #selector(cancelFileTranscription), keyEquivalent: ""
        )
        cancelFile.target = self
        cancelFile.isEnabled = false
        menu.addItem(cancelFile)
        cancelFileItem = cancelFile
        let resetMicrophone = NSMenuItem(
            title: "Reset Microphone", action: #selector(resetMicrophone), keyEquivalent: ""
        )
        resetMicrophone.target = self
        menu.addItem(resetMicrophone)
        menu.addItem(.separator())
        let addFeedback = NSMenuItem(title: "Add Feedback…", action: #selector(addFeedback), keyEquivalent: "")
        addFeedback.target = self
        menu.addItem(addFeedback)
        let openFeedback = NSMenuItem(title: "Open Feedback Log", action: #selector(openFeedbackLog), keyEquivalent: "")
        openFeedback.target = self
        menu.addItem(openFeedback)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit whisper", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu

        statusLineItem = statusLine
        refreshChecks()

        // Off the launch path: run the first-run permission flow, then assemble (which
        // downloads the ~547MB model on first run).
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        // Show the system mic prompt once if the user hasn't decided yet.
        if PermissionsPresentation.shouldRequestMicrophone(permissions.state()) {
            _ = await permissions.requestMicrophone()
        }
        let state = permissions.state()
        log("permissions: microphone=\(state.microphone), accessibility=\(state.accessibilityGranted)")
        // Prompt for Accessibility if it's missing — but never block boot on it. The old
        // code ran a modal here, which on a menu-bar (.accessory) app can fail to surface
        // and leave launch hung at "starting…". Instead we fire the non-blocking system
        // prompt and always assemble; armHotkey then polls until the grant lands, so the
        // hotkey starts working the moment Accessibility is enabled — no relaunch needed.
        if !state.accessibilityGranted {
            permissions.promptAccessibility()
        }
        if let summary = PermissionsPresentation.summary(state) { setStatus(summary) }
        await assemble()
    }

    private func assemble() async {
        let engine: LocalWhisperEngine
        do {
            engine = try await LocalWhisperEngine.resident()
        } catch {
            setStatus("model unavailable — \(error)")
            return
        }

        let audio = AVAudioEngineAudioSource()
        try? audio.prewarm()  // hold the mic hot so the first key-down doesn't clip the first word
        // Route insertion: dictation into our own Add Feedback editor inserts directly
        // (see RoutingTextInjector); everything else goes through the pasteboard injector.
        let routingInjector = RoutingTextInjector(external: PasteboardTextInjector())
        self.routingInjector = routingInjector
        let controller = DictationController(
            audio: audio,
            engine: engine,
            injector: routingInjector,
            settings: settings
        )
        audio.onCaptureInvalidated = { reason in
            Task {
                switch reason {
                case .deviceChanged:
                    await controller.cancelRecording(reason: "microphone changed — try again")
                case .manualReset:
                    await controller.cancelRecording(reason: "microphone reset — try again")
                }
            }
        }
        controller.onStateChange = { [weak self] state in self?.render(state) }
        controller.onOutcome = { [weak self] outcome in self?.report(outcome) }
        self.controller = controller
        self.audioSource = audio
        self.whisperEngine = engine
        let microphoneResetCoordinator = MicrophoneResetCoordinator {
            await audio.resetMicrophone()
        }
        microphoneResetCoordinator.onStatus = { [weak self] status in self?.setStatus(status) }
        self.microphoneResetCoordinator = microphoneResetCoordinator

        // Pay the one-time model/Metal warm-up now so the first real dictation isn't slow.
        await controller.warmUp()

        // Serialize key events: the hotkey callbacks only `yield` (synchronous, ordered),
        // and this single consumer applies them one at a time, so began always precedes its
        // ended even for a fast tap.
        let (stream, continuation) = AsyncStream<Activation>.makeStream()
        self.activations = continuation
        Task {
            for await event in stream {
                log("hotkey \(event)")
                switch event {
                case .began:
                    self.fileCoordinator?.pauseForLiveDictation()
                    await controller.activationBegan()
                case .ended: await controller.activationEnded()
                }
            }
        }

        armHotkey()
    }

    /// Start (or restart) the hotkey for the current activation key, rewiring it to the
    /// activation stream. Called at assembly and whenever the key setting changes.
    private func armHotkey() {
        hotkey?.stop()
        let hotkey = CGEventTapHotkeySource(key: settings.activationKey)
        hotkey.onActivationBegan = { [weak self] in self?.activations?.yield(.began) }
        hotkey.onActivationEnded = { [weak self] in self?.activations?.yield(.ended) }
        do {
            try hotkey.start()
        } catch {
            self.hotkey = nil
            setStatus("hold-to-talk off — enable whisper under Accessibility (starts automatically once you do)")
            scheduleAccessibilityRetry()
            return
        }
        self.hotkey = hotkey
        accessibilityRetry?.cancel()
        accessibilityRetry = nil
        setStatus("ready — hold \(settings.activationKey.displayName) to dictate")
    }

    /// Poll for the Accessibility grant, then arm the hotkey — so enabling whisper in
    /// System Settings takes effect immediately instead of needing a relaunch. Idle cost
    /// is one boolean check a second, only while the grant is still missing.
    private func scheduleAccessibilityRetry() {
        guard accessibilityRetry == nil else { return }
        accessibilityRetry = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if self.permissions.accessibilityGranted {
                    self.armHotkey()  // arms and clears this retry
                    return
                }
            }
        }
    }

    // MARK: - Config menu

    private func buildConfigItems(into menu: NSMenu) {
        let keyMenu = NSMenu()
        for choice in ModifierKey.choices {
            let item = NSMenuItem(title: choice.name, action: #selector(selectActivationKey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.key  // the value itself, not an index into choices
            keyMenu.addItem(item)
            keyItems.append(item)
        }
        let keyParent = NSMenuItem(title: "Activation Key", action: nil, keyEquivalent: "")
        keyParent.submenu = keyMenu
        menu.addItem(keyParent)

        let modeMenu = NSMenu()
        let modes: [(String, Settings.Mode)] = [("Push-to-Talk (hold)", .pushToTalk), ("Toggle (tap)", .toggle)]
        for (title, mode) in modes {
            let item = NSMenuItem(title: title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            modeMenu.addItem(item)
            modeItems.append(item)
        }
        let modeParent = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeParent.submenu = modeMenu
        menu.addItem(modeParent)

        let restore = NSMenuItem(title: "Restore clipboard after paste", action: #selector(toggleRestore), keyEquivalent: "")
        restore.target = self
        menu.addItem(restore)
        restoreItem = restore

        let normalize = NSMenuItem(
            title: "Normalize Text on Live Dictation", action: #selector(toggleLiveNormalization), keyEquivalent: ""
        )
        normalize.target = self
        menu.addItem(normalize)
        normalizeLiveItem = normalize

        let cueMenu = NSMenu()
        for volume in CueVolume.allCases {
            let item = NSMenuItem(title: volume.title, action: #selector(selectCueVolume(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: volume.rawValue)
            cueMenu.addItem(item)
            cueVolumeItems.append(item)
        }
        let cueParent = NSMenuItem(title: "Cue Volume", action: nil, keyEquivalent: "")
        cueParent.submenu = cueMenu
        menu.addItem(cueParent)
    }

    private func refreshChecks() {
        for item in keyItems {
            item.state = (item.representedObject as? ModifierKey == settings.activationKey) ? .on : .off
        }
        for item in modeItems {
            item.state = (item.representedObject as? Settings.Mode == settings.mode) ? .on : .off
        }
        restoreItem?.state = settings.restoreClipboard ? .on : .off
        normalizeLiveItem?.state = settings.normalizeLiveDictation ? .on : .off
        for item in cueVolumeItems {
            item.state = (item.representedObject as? NSNumber)?.floatValue == settings.cueVolume.rawValue ? .on : .off
        }
    }

    @objc private func selectActivationKey(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? ModifierKey else { return }
        settings.activationKey = key
        persist()
        armHotkey()  // re-tap on the newly chosen key
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? Settings.Mode else { return }
        settings.mode = mode
        persist()
    }

    @objc private func toggleRestore() {
        settings.restoreClipboard.toggle()
        persist()
    }

    @objc private func toggleLiveNormalization() {
        settings.normalizeLiveDictation.toggle()
        persist()
    }

    @objc private func selectCueVolume(_ sender: NSMenuItem) {
        guard let raw = (sender.representedObject as? NSNumber)?.floatValue,
              let volume = CueVolume(rawValue: raw) else { return }
        settings.cueVolume = volume
        applyCueVolume()
        persist()
    }

    private func applyCueVolume() {
        let amplitudes = SoundVolumePresentation.amplitudes(for: settings.cueVolume)
        startSound?.volume = amplitudes.start
        stopSound?.volume = amplitudes.stop
    }

    /// Save the change and keep every consumer of `settings` in sync: the controller reads
    /// mode and restore-clipboard live, so it must never hold a stale copy.
    private func persist() {
        settingsStore.save(settings)
        controller?.settings = settings
        refreshChecks()
    }

    // MARK: - Presentation

    private static func bundledSound(named name: String) -> NSSound? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
            return nil
        }
        return NSSound(contentsOf: url, byReference: false)
    }

    private func render(_ state: DictationController.State) {
        iconAnimator?.update(state: state)
        let sound = presenter.advance(to: state)
        switch sound {
        case .start: startSound?.play()
        case .stop: stopSound?.play()
        case nil: break
        }
    }

    private func setIcon() {
        guard let button = statusItem?.button else { return }
        let base: NSImage
        if let image = Bundle.main.image(forResource: "whisper-menu-bar-icon") {
            base = image
        } else {
            log("menu-bar icon resource missing; using waveform fallback")
            base = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Dictation")
                ?? NSImage(size: NSSize(width: 24, height: 18))
        }
        button.imageScaling = .scaleProportionallyDown
        // The animator owns the icon from here: it renders the normal frame now (idle
        // waveform, visible at launch in either menu-bar appearance) and later reflects the
        // recording, processing, and result states.
        iconAnimator = MenuBarIconAnimator(button: button, renderer: IconRenderer(base: base))
    }

    /// Turn each dictation result into a status-line message. A failure most often means a
    /// permission went missing at use time (e.g. mic denied), so name what's still needed.
    private func report(_ outcome: DictationController.Outcome) {
        iconAnimator?.update(outcome: outcome)  // drive the result icon for every outcome
        defer { fileCoordinator?.resumeAfterLiveDictation() }
        switch outcome {
        case .injected:
            setStatus("ready — hold \(settings.activationKey.displayName) to dictate")
        case .noAudio:
            setStatus("no speech detected — try again")
        case .failed(let reason):
            if reason == "microphone changed — try again" || reason == "microphone reset — try again" {
                setStatus(reason)
                return
            }
            // A missing permission is the usual cause; name it. Otherwise keep the reason.
            setStatus(PermissionsPresentation.summary(permissions.state()) ?? "dictation failed — \(reason)")
        case .idle:
            break
        }
    }

    // MARK: - File transcription

    @objc private func transcribeAudioFile() {
        guard fileCoordinator == nil, let engine = whisperEngine else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Audio, .wav]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let plan = try AudioDecoding.plan(for: url)
            let coordinator = FileTranscriptionCoordinator(engine: engine) { chunk in
                try await Task.detached {
                    CapturedAudio(samples: try AudioDecoding.samples16kMono(fromFile: url, chunk: chunk))
                }.value
            }
            coordinator.onStateChange = { [weak self, weak coordinator] state in
                guard let self else { return }
                self.cancelFileItem?.isEnabled = coordinator?.isBusy == true
                self.transcribeFileItem?.isEnabled = coordinator?.isBusy != true
                if let status = FileMenuPresentation.status(for: state) { self.setStatus(status) }
                if state == .idle || state.isTerminalFailure {
                    self.fileCoordinator = nil
                    self.cancelFileItem?.isEnabled = false
                    self.transcribeFileItem?.isEnabled = true
                    if state == .idle { self.setStatus("ready — hold \(self.settings.activationKey.displayName) to dictate") }
                }
            }
            coordinator.onResult = { [weak self] result in self?.showFileResult(result) }
            fileCoordinator = coordinator
            _ = coordinator.start(sourceURL: url, plan: plan)
        } catch {
            setStatus("can't transcribe file — \(error.localizedDescription)")
        }
    }

    @objc private func cancelFileTranscription() { fileCoordinator?.cancel() }

    private func showFileResult(_ result: FileTranscriptionResult) {
        let resultWindow = FileResultWindowController(result: result, normalizer: DeterministicTextNormalizer())
        resultWindows.append(resultWindow)
        resultWindow.onClose = { [weak self, weak resultWindow] in
            guard let self, let resultWindow else { return }
            self.resultWindows.removeAll { $0 === resultWindow }
        }
        NSApp.activate(ignoringOtherApps: true)
        resultWindow.showWindow(nil)
    }

    @objc private func resetMicrophone() {
        Task { await microphoneResetCoordinator?.performReset() }
    }

    private func setStatus(_ text: String) {
        statusLineItem?.title = "\(brand) — \(text)"
        log(text)
    }

    // MARK: - Feedback log

    /// Prompt for a note and append it to the feedback log. A multi-line text view is the
    /// accessory so a longer thought fits; Enter inserts a newline, the Save button commits.
    @objc private func addFeedback() {
        let alert = NSAlert()
        alert.messageText = "Add feedback"
        alert.informativeText = "Jot a note for the next round of improvements. Saved to the feedback log."

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 96))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.autoresizingMask = [.width, .height]
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.allowsUndo = true
        scroll.documentView = textView
        alert.accessoryView = scroll

        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = textView

        // While this editor is up and focused, dictation inserts into it directly instead
        // of via pasteboard paste (which loses the race against clipboard restoration).
        // The strong `target` here keeps the weak router reference alive for the modal's
        // life; the defer clears it so a closed editor can't receive a late transcript.
        let target = TextViewInsertionTarget(textView: textView)
        routingInjector?.inProcessTarget = target
        defer { routingInjector?.inProcessTarget = nil }

        let response = withExtendedLifetime(target) { alert.runModal() }
        guard response == .alertFirstButtonReturn else { return }

        do {
            let saved = try feedbackLog.append(textView.string)
            setStatus(saved ? "feedback saved" : "ready — hold \(settings.activationKey.displayName) to dictate")
        } catch {
            setStatus("couldn't save feedback — \(error.localizedDescription)")
        }
    }

    /// Open the feedback log in the default handler, revealing it in Finder if it's empty
    /// (nothing jotted yet), so the user always lands somewhere sensible.
    @objc private func openFeedbackLog() {
        let url = feedbackLog.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        iconAnimator?.stop()
    }
}

let app = NSApplication.shared
// Menu-bar agent: no dock icon, no main window. (The .app-bundle equivalent is
// LSUIElement=true in Info.plist; a later packaging step adds the bundle.)
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
