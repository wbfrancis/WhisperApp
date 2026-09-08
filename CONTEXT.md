# WhisprFlow Replacement — CONTEXT

A barebones, seamless dictation tool. **macOS is the priority platform** (this doc); iPhone is a later, separate build.

## Goal

Replace WhisprFlow with the most barebones feature set: press a key, talk, get accurate text inserted where the cursor is. No analytics or "analysis" features — unless a signal can be fed *back* into dictation to improve accuracy (e.g. custom vocabulary).

## Language

**Live dictation**:
Speech captured from the current microphone while the activation key is active, then inserted at the cursor.
_Avoid_: Recording import, file transcription

**Short capture**:
A live dictation shorter than 0.5 seconds. The app treats it as no speech; a capture of exactly 0.5 seconds is valid.
_Avoid_: Empty capture

**File transcription**:
A local, English-language conversion of a user-selected `.m4a` or `.wav` recording of at most 30 minutes into editable text with Copy and Save actions. It does not insert text at the cursor.
_Avoid_: Upload, imported dictation

**File transcription progress**:
The percentage of file chunks that the app completed. The menu shows this percentage while a file is in progress; an interrupted chunk does not advance it.

**File transcription controls**:
The menu status line shows file progress, and **Cancel File Transcription** stops the job. The app opens no progress window; it opens a file result only after completion or cancellation.

**File transcription preemption**:
Live dictation interrupts only the active file chunk, takes priority, then lets file transcription retry that chunk and continue. Completed chunks remain intact.

**File result**:
The editable raw transcript that appears when file transcription finishes. Its **Normalize Text** action changes the text without another transcription, and standard Undo restores the raw result.

**Partial file result**:
The editable text from every completed file chunk when the user cancels transcription. It is labeled **Partial** and keeps the same Copy and Save actions as a complete file result; the unfinished chunk is absent.

**Raw transcript**:
The text that the local transcription model returns, with only outer whitespace removed.

**Normalize Text**:
An optional deterministic pass that converts spoken dates and times in a raw transcript into visual text. Dates use an unambiguous written-month form, and relative dates remain unchanged. Inferred visual lists need a future language-model implementation and are not part of this round.
_Avoid_: Transcription cleanup

**Normalize Text on Live Dictation**:
The saved menu toggle that applies Normalize Text before the app inserts live dictation. It is enabled by default.

**Cue volume**:
One saved volume level shared by the recording start and stop sounds. Its levels are Mute, 25%, 50%, 75%, and 100%; the current volume remains the default.

**Microphone recovery**:
The automatic repair of live capture after the system input device changes. A change during live dictation discards the partial capture and reports **microphone changed — try again**. A manual **Reset Microphone** action during live dictation cancels that dictation and reports **microphone reset — try again**. During file transcription, it repairs the microphone without stopping the file job. A full app restart is not part of this recovery round.

**Status dot**:
The live-dictation state shown by a colored dot in the bottom-right foreground of the menu-bar icon, while the waveform behind it stays the normal shape and color. Idle shows no dot: just the normal waveform, visible in both light and dark menu bars, never fading to an invisible icon. Recording is a solid red dot. Transcription and paste share one slow yellow blink, crisp on and off. A successful insertion is a solid blue dot for one second, then fades out over one second. A failed live dictation blinks the dot orange quickly for five seconds, then fades out. A short capture or no-speech result gives one brief orange flash that fades out. The blinks never fade in or out; only the success and failure results fade, since those are the end states. A new recording during any result animation replaces the dot at once with solid red. File transcription does not drive this dot; its progress stays in the menu status line.

**Dot colors**:
The saved `#RRGGBB` colors for Recording, Processing, Success, and Failure status dots. The menu can edit, preview, and reset each color; new settings take effect immediately.
_Avoid_: Theme, palette

**Insertion success**:
The state the blue dot reports: the insertion operation returned without error. For an external app it does not claim the destination visibly accepted the text, only that the paste was posted; for Add Feedback it means the transcript was inserted into the editor.

**Add Feedback**:
A menu action that appends a typed or dictated note to the feedback log. Its editor uses readable system text and background colors for the current macOS appearance. Dictated speech is inserted at the insertion point, replacing any selection, and keeps the standard edit shortcuts, Undo, Save, and Cancel. It inserts the new transcript, never the previous clipboard. The restore-clipboard setting still holds: with restore on the clipboard is left untouched, with it off the transcript is left on the clipboard.
_Avoid_: feedback box, note dialog

## Settled facts (environment)

- **Machine**: macOS 14.6.1 (Sonoma), Apple Silicon (arm64).
- **Toolchain present**: full Xcode 16.2, Swift 6.0.3, Homebrew 6.0.18, Python 3.14, Node 24. No whisper installed yet.
- Implication: a native Swift menu-bar app is fully viable; local whisper.cpp with Metal/CoreML acceleration is viable; cloud APIs are viable.
- Note: `SpeechAnalyzer` (Apple's newer STT) is macOS 26+ only, so it is **not** available on 14.6. On-device options here are whisper.cpp or the older `SFSpeechRecognizer`.

## Deferred (iPhone — researched, out of scope this session)

- iOS custom keyboard extensions **cannot** record the microphone (Apple blocks it at runtime; "Full Access" does not grant mic). iPhone dictation requires the **companion-app pattern**: keyboard button → containing app records + transcribes → shared App Group → keyboard inserts text. See `research/ios-keyboard-mic-constraint.md`.

## Settled decisions (Round 1)

- **Engine**: Local **whisper.cpp** for v1, behind a `TranscriptionEngine` abstraction (protocol) so a cloud engine can drop in later without touching the rest of the app.
- **Activation**: **Push-to-talk** by default (hold to talk, release to transcribe+insert), with a config option to switch to **Toggle**. Default key is **`fn`**, but the hotkey must be easily configurable.
- **Text injection**: **Pasteboard paste with save-and-restore** of the previous clipboard contents by default (paste is invisible to the user's clipboard). Config toggle to **disable restore**, which leaves the dictated text sitting on the clipboard.
- **App shape**: Native **Swift menu-bar agent** (`LSUIElement`), built as a **personal tool** — ad-hoc signed, no notarization/distribution.
- **Accuracy-feedback feature (custom vocabulary)**: **deferred to v2.** v1 is a clean dictate-and-insert loop. Local whisper's `initial_prompt` keeps the door open.

## Settled decisions (Round 2)

- **Model**: `large-v3-turbo`, quantized, with a CoreML encoder. Drop to `medium` only if warm-up/RAM is a problem.
- **Timing**: transcribe-on-release for v1 (no streaming partials).
- **Feedback**: menu-bar icon state change + subtle start/stop sound. No floating overlay in v1.
- **Hotkey**: still resolving — see Q7b (bare spacebar is not viable; picking the single hold-key).

## Settled decisions (Round 3)

- **Hotkey (resolved)**: **Right Option (`⌥`) held alone** is the default push-to-talk key. Bare spacebar is ruled out (it's a real character globally and can't be trapped without breaking space typing). Fully reconfigurable to `fn` or a chord.
- **Model acquisition**: **download on first run** into `~/Library/Application Support/`, not bundled in the app.
- **First-run permissions**: a **minimal guided first-run window** — request Microphone, then deep-link the user to the Accessibility pane with a direct "Open" button.

## Frontier: empty — design tree complete.

## Prototype outcome (spike closed 2026-08-20 — see `prototype/RESULTS.md`)

Both go/no-go questions passed:
- **Latency**: local whisper turbo q5_0 gives ~1 s warm release→text (encode ~850 ms is
  a fixed floor up to whisper's 30 s window). Good enough for transcribe-on-release.
- **Injection**: pasteboard paste + ⌘V + save-and-restore lands text reliably in real apps.

**Findings that become v1 spec requirements:**
1. Warm whisper up at launch (transcribe a silent buffer once) to hide the one-time ~18 s
   Metal shader compile.
2. In the capture code, release the `AVAudioFile` before finishing so the WAV header
   finalizes (otherwise transcription gets a 0-length file).
3. Core ML / ANE encoder is the lever to go sub-second later; not needed for v1.

---

## v1 build summary (the shared understanding)

A native Swift **menu-bar agent** (`LSUIElement`, personal tool, ad-hoc signed, no notarization) that does one thing: **hold Right Option → talk → release → accurate text pasted at the cursor.**

**The loop:**
1. A global `CGEventTap` watches for **Right Option** held alone (configurable; supports push-to-talk default and a toggle mode).
2. On key-down, capture mic audio via `AVAudioEngine` (16kHz mono). Menu-bar icon flips to "recording" + a subtle start sound.
3. On key-up, stop capture, play a stop sound, and transcribe the whole utterance (**transcribe-on-release**, no streaming).
4. Transcription runs through a `TranscriptionEngine` protocol. v1 impl = **local whisper.cpp**, `large-v3-turbo` quantized + CoreML encoder, downloaded on first run. The protocol keeps a cloud engine as a drop-in later.
5. Insert the transcript by **pasteboard paste + ⌘V**, with **save-and-restore** of the prior clipboard by default (config toggle to skip restore and leave the text on the clipboard).

**Permissions**: Microphone + Accessibility, requested through a guided first-run window.

**Explicitly deferred to v2**: custom-vocabulary / accuracy-feedback layer (whisper `initial_prompt` keeps the seam open), streaming partials, floating on-screen indicator, cloud engine, notarization/distribution.

**Separate track (researched, not this build)**: iPhone via the companion-app pattern — keyboard extensions can't record mic. See `research/ios-keyboard-mic-constraint.md`.
