# Feedback Round Implementation Plan

Implement the feedback round recorded in `CONTEXT.md`. Preserve the existing waveform-icon and approved A1 cue work already present in the dirty worktree.

## Read first

1. Read `AGENTS.md`, `CONTEXT.md`, and this plan.
2. Read the current diff before editing. Treat every existing change as user-owned work to preserve.
3. Read these implementation seams:
   - `Sources/DictationKit/Protocols.swift`
   - `Sources/DictationKit/DictationController.swift`
   - `Sources/DictationKit/LocalWhisperEngine.swift`
   - `Sources/DictationKit/AVAudioEngineAudioSource.swift`
   - `Sources/DictationKit/AudioDecoding.swift`
   - `Sources/DictationKit/SettingsStore.swift`
   - `Sources/DictationKit/TimeFormatting.swift`
   - `Sources/whisper/main.swift`
   - the matching tests under `Tests/DictationKitTests/`
4. Run `swift test`. The confirmed starting point is 103 passing tests on 2026-08-25.

Stop and report the difference if the worktree no longer contains the expected icon, sound, resource, and `CONTEXT.md` changes. Reconcile nothing silently.

## Product contract

The domain language and final product choices live in `CONTEXT.md`. This round must deliver all of these behaviors:

- A live capture shorter than 0.5 seconds produces the existing no-speech outcome. Exactly 0.5 seconds remains valid.
- The Add Feedback editor supports standard Cut, Copy, Paste, and Select All shortcuts.
- One saved cue-volume setting controls both approved A1 sounds. The menu choices are Mute, 25%, 50%, 75%, and 100%; the current playback level remains the default.
- **Normalize Text on Live Dictation** is saved, enabled by default, and controls normalization before live insertion.
- This round's deterministic Normalize Text pass handles clock times and unambiguous written-month dates. It leaves relative dates unchanged.
- Inferred list formatting is deferred. Keep a `TextNormalizer` boundary that can accept an LLM implementation later.
- **Transcribe Audio File…** accepts local English `.m4a` and `.wav` recordings of at most 30 minutes.
- File transcription returns editable text in a result window with Copy and Save. It never inserts at the cursor.
- The file result starts with the raw transcript. A one-shot **Normalize Text** action changes the editable text without retranscription; standard Undo restores the prior text.
- File work runs in checkpointed chunks through the one resident Whisper model. The menu shows the committed-chunk percentage and exposes **Cancel File Transcription**.
- Live dictation starts capture immediately, preempts only the active file chunk, transcribes with priority, then lets the file retry that chunk and continue.
- User cancellation opens completed chunks as an editable result labeled **Partial**. It excludes the active unfinished chunk. If no chunk completed, show a canceled state without an empty editor.
- Input-device changes recover automatically. A change during live dictation discards that capture and reports **microphone changed — try again**.
- **Reset Microphone** uses the same recovery path. During live dictation it cancels the capture and reports **microphone reset — try again**. During file transcription it leaves file work running.
- This round does not add `.mp4`, inferred lists, an LLM runtime, a second Whisper context, or **Restart App**.

## Architecture boundaries

Keep OS objects thin and put state decisions into testable types.

### Raw transcription and normalization

`LocalWhisperEngine` must return raw model text with outer whitespace removed. Move the unconditional `TimeFormatting.format` call out of the engine.

Add a `TextNormalizer` protocol and a deterministic implementation. Compose the existing clock-time formatter with a date formatter. The deterministic implementation must preserve every unmatched character, whitespace run, newline, and punctuation mark.

Support test-backed written-month forms such as:

- `August twenty-fifth twenty twenty-six` → `August 25, 2026`
- `August twenty fifth` → `August 25`
- digit-day and digit-year equivalents for the same unambiguous month-led shape

Leave relative forms such as `today`, `tomorrow`, and `next Tuesday` unchanged. Do not interpret number-only dates or infer lists.

Apply the normalizer in the live pipeline only when `normalizeLiveDictation` is enabled. Keep the raw file transcript separately so the result window can normalize without a new Whisper call.

Completion criterion: engine tests prove raw output, normalizer tests prove supported replacements and exact preservation, and live controller tests prove the setting gates normalization.

### One off-main Whisper worker

Move blocking `whisper_full` work off `@MainActor`. One dedicated serial execution boundary must own and use the single C context. A serial dispatch queue is a good fit because a blocking actor method cannot receive a higher-priority cancellation message until the C call returns.

Keep these invariants:

- One model load and one resident context.
- No concurrent call uses the same context; `whisper_full` is not thread-safe for one context.
- Live and file calls use separate parameter profiles. Preserve the current short-utterance settings for live work. Use multi-segment file settings and prevent prior live text from becoming file context.
- The C call supports cooperative abort through `ggml_abort_callback`. A lock-guarded cancellation token must outlive the call and must be writable outside the worker queue.
- Map cooperative abort to an internal cancellation/preemption result, not a transcription failure shown to the user.
- Warm-up still completes before the app reports ready.

If Swift cannot safely bind the callback and `user_data` lifetime directly, add the smallest C shim needed. Keep ownership explicit and test the Swift-side cancellation state separately.

Completion criterion: tests prove strict serialization, live priority, cooperative cancellation mapping, one model owner, and main-actor responsiveness while a fake worker blocks.

### File chunks and scheduling

Add a file-transcription coordinator independent of `DictationController`. It owns one file job, its committed text, progress, pause state, and cancellation.

Decode incrementally. The current `AudioDecoding.samples16kMono(fromFile:)` reads a whole file and is unsuitable for the 30-minute path. Read source frames in bounded buffers and resample them to 16 kHz mono without retaining the whole decoded recording.

Before transcription, determine stable chunk boundaries and the total chunk count. Use approximately 25–28 seconds of unique audio per chunk, with a small overlap or silence-aware boundary to protect split words. Keep the choice in named constants. Merge overlap text deterministically and cover duplicate/missing-boundary behavior with fixtures. Do not count a chunk as complete until transcription and overlap merge both succeed.

Scheduling behavior:

1. Start or continue the next file chunk when no live job is pending.
2. On live activation-down, start microphone capture immediately, mark the file paused, and request cancellation of its active chunk.
3. On live release, enqueue live transcription ahead of file work.
4. After live insertion reaches a terminal outcome, retry the interrupted file chunk and continue.
5. Repeated live dictations can repeat this cycle without losing committed chunks or advancing progress falsely.

Progress is `completedChunkCount / totalChunkCount`, floored to an integer percentage so only the final commit can show 100%. Show `transcribing file — N%` in the menu. While live work owns the model, keep the percentage and show `paused for live dictation — N%`. A retry never moves progress backward or forward until it commits.

User cancellation stops the active chunk cooperatively. Open committed text as **Partial** when at least one chunk exists. Use a suggested `-partial.txt` filename in Save, but do not add a status header to transcript text.

Completion criterion: coordinator tests cover success, progress, preemption, retry, repeated preemption, cancel-before-first-commit, cancel-after-commit, decode failure, Whisper failure, overlap merge, and a second-file request while busy.

### File UI

Add these menu actions and states:

- **Transcribe Audio File…**
- **Cancel File Transcription**, enabled only while a file job exists
- the existing status line reused for percentage, pause, failure, and ready text

Use `NSOpenPanel` with `.m4a` and `.wav` filtering. Check the decoded duration before starting the job. Reject files longer than 30 minutes, empty/no-audio files, corrupt files, and unsupported formats with clear messages.

Do not show a progress window. On completion or partial cancellation, open one AppKit result window with:

- an editable plain-text `NSTextView`
- a visible Complete or Partial state outside the transcript content
- Copy, Save, and Normalize Text actions
- a one-shot normalization edit registered with the text view's undo manager
- a Save default derived from the source filename; add `-partial` for partial results

Retain the result-window controller for the window lifetime. Keep the raw transcript immutable in the controller even after the editor changes.

Completion criterion: pure presentation/state tests cover menu titles and enabled states; a signed-app smoke test covers picker focus, result editing, Copy, Save, Normalize, Undo, and partial labeling.

### Live capture minimum

Keep `CapturedAudio` as 16 kHz mono and put its sample-rate and minimum-duration facts in named domain constants. Gate the recording in `DictationController` before it enters the transcribing state.

Boundary tests must prove:

- 7,999 samples produce no speech, with no engine or injector call.
- 8,000 samples reach transcription.
- Longer captures remain unchanged.

Completion criterion: the controller returns idle through the existing no-speech outcome for the rejected capture and emits the normal stop cue once.

### Microphone recovery

Refactor `AVAudioEngineAudioSource` around a small fakeable engine-session boundary or recovery state machine. Preserve the hot-microphone behavior that prevents first-word clipping.

Observe `AVAudioEngineConfigurationChangeNotification` for the active engine. Debounce route-change bursts and schedule recovery outside the notification callback. Recovery must:

1. Stop collection and discard partial samples.
2. Mark the source unavailable.
3. Remove the installed tap exactly once.
4. Stop and reset the existing engine instance.
5. Wait/retry while the input format has zero rate or channels.
6. Build a new resampler and tap from the current hardware format.
7. Prepare and start the engine.

`ensureRunning` must check both the app state and `engine.isRunning`, so a missed notification self-heals on the next activation. Keep the existing engine instance during recovery; do not deallocate it inside its configuration-change callback.

Expose one manual reset operation that uses this same path. Add an explicit controller cancellation operation so a reset or device change during live dictation cannot leave `DictationController` in `.recording`.

Completion criterion: fake-backend tests prove idle recovery, active-capture cancellation, stale-running self-heal, notification coalescing, transient zero-format retry, failed restart retryability, one-tap installation, and manual/automatic path equivalence.

### Settings and sound volume

Add persisted values for cue volume and live normalization. Decode old `settings.v1` JSON with missing fields without resetting the existing activation key, mode, or clipboard choice.

Use a checked Cue Volume submenu with Mute, 25%, 50%, 75%, and 100%. One selection updates both `NSSound` instances and persists immediately. Keep 100% as the migration/default value so the approved cue playback does not change silently.

Add the checked **Normalize Text on Live Dictation** menu item, enabled by default. It persists immediately and updates the live controller/pipeline without a restart.

Completion criterion: settings tests cover defaults, every new field, legacy decoding, corrupt-data fallback, round trips, and independent field changes. Presentation tests cover menu selection state and both sound objects receiving the same amplitude.

### Feedback editor shortcuts

Install the standard application Edit command chain for Cut, Copy, Paste, and Select All. Let `NSTextView` use the normal responder chain; keep `FeedbackLog` unchanged.

Completion criterion: menu-construction tests prove the standard selectors exist, and the signed app manually pastes clipboard text into Add Feedback with Command-V and saves it.

## Implementation order

1. Protect the dirty-tree baseline and add failing tests for settings migration, the 0.5-second boundary, and raw-vs-normalized output.
2. Separate raw transcription from normalization, add date formatting, and wire the live toggle.
3. Move Whisper execution off-main and add cooperative cancellation with one resident context.
4. Add incremental file decoding, chunk planning/merge, and the file coordinator with live priority.
5. Add file menu state, progress, cancellation, and result-window behavior.
6. Add microphone recovery and manual reset through one tested path.
7. Add cue-volume persistence/menu behavior and standard Edit shortcuts.
8. Run the full automated and signed-app checks below. Fix regressions without removing or replacing the existing icon/sound work.

Each step ends only when its focused tests pass and all prior tests remain green.

## Automated checks

Run at minimum:

```sh
swift test
scripts/bundle.sh
codesign --verify --deep --strict build/whisper.app
```

Also run `swift run eval` when the environment has Full Disk Access. Keep the existing corpus result at 0% WER by applying the deterministic normalizer explicitly in the eval path where expected fixtures contain normalized times.

Add fixture-backed decoding checks for:

- AAC or ALAC `.m4a`
- PCM `.wav`
- stereo-to-mono and non-16-kHz resampling
- a corrupt file
- an empty/no-audio file
- the 30-minute boundary without committing a large fixture to Git

Add one boundary-quality fixture whose spoken phrase crosses a planned chunk edge. The merged transcript must contain every expected word once.

## Signed-app manual checks

Build and run the signed `.app`; do not use `swift run` for these checks.

1. Confirm the existing waveform icon and approved start/stop cues still work.
2. Check every cue-volume preset, including Mute, and restart the app to check persistence.
3. Paste into Add Feedback with Command-V, then save and inspect the log.
4. Check an accidental tap produces the no-speech status and a normal short utterance still transcribes. The automated boundary tests own the exact 0.49/0.50-second check.
5. Transcribe one `.m4a` and one `.wav`; edit, copy, save, normalize, and undo each result.
6. Check menu percentage advances from committed chunks and reaches 100% only after the last chunk commits.
7. Start live dictation during a file job. Confirm capture starts immediately, the file shows paused at the same percentage, live text inserts, and file progress resumes.
8. Cancel after at least one committed chunk. Confirm the Partial result excludes the active chunk and saves with a `-partial` suggestion.
9. Switch Mac microphone → AirPods and AirPods → Mac microphone while idle. Confirm the orange indicator returns and the next dictation preserves its first word.
10. Switch devices during live dictation. Confirm no truncated text inserts and the status asks for a retry.
11. Use Reset Microphone while idle, during live dictation, and during file transcription. Confirm only active live dictation is canceled.

## Done

The round is complete only when:

- every product-contract item works;
- the full test suite passes;
- the eval corpus remains at 0% WER when it can run;
- the signed bundle and code signature check pass;
- the manual checks preserve the existing icon, cues, hotkey, first-word capture, clipboard behavior, and permission flow;
- no existing user-owned change is lost;
- `CONTEXT.md` and this plan agree with the shipped behavior.

Report the files changed, tests run, manual checks completed, and any check that still needs the user's hardware interaction. Leave commits and pushes to the user unless the user gives separate authorization.
