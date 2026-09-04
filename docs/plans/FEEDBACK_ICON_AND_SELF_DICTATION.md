# Feedback dictation and menu icon implementation plan

## Scope and approval

The user confirmed this design on September 3, 2026 and requested a plan for the next session. Implement two items from `~/Library/Application Support/whisper/feedback.md`: dictation into Add Feedback pastes the old clipboard, and the menu icon needs live dictation status.

The decisions below are settled. Proceed with implementation when the next session receives the handoff prompt. Ask about a product decision only if new evidence makes this design impossible or contradictory.

## Agreed behavior

| Event or state | Icon behavior |
| --- | --- |
| Idle | Existing waveform, visible in the normal macOS menu-bar appearance. |
| Recording | Solid red waveform. |
| Transcription and paste | Yellow pulse once per second, continuing through injection. |
| Successful insertion | Solid green for one second, then fade to the normal icon over one second. |
| Failed live dictation | Orange pulse twice per second for five seconds, then normal icon. |
| Short capture or no speech | One brief orange flash, then normal icon; no additional sound. |
| New recording during a result animation | Replace the animation immediately with solid red. |
| File transcription | Existing menu progress only; it does not drive these icon states. |

Green means the insertion operation returned successfully. For external apps, it does not claim that the destination visibly accepted the text. Preserve the existing start/stop sounds and saved cue volume. A short or silent recording adds no new beep; it does not remove the existing recording cues.

Use a 250 ms no-speech flash as an implementation default for “brief,” not a separately approved duration. Keep the waveform shape and dimensions. Normal idle remains visible in light and dark menu bars; it never fades to an invisible icon. Color shades and pulse easing are implementation choices, subject to visual review.

Add Feedback must accept dictated text at the insertion point, replace selected text normally, and retain standard edit shortcuts, Undo, Save, Cancel, multiline entry, and the existing log format. Preserve the restore-clipboard setting and external-app dictation.

## Start from the current workspace

Read `AGENTS.md`, `CONTEXT.md`, and applicable agent/skill instructions. Inspect current status and diffs before editing. This workspace already contains extensive uncommitted and untracked work from the earlier feedback round, including audio recovery, file transcription, normalization, resources, and tests. Preserve it; the current files are the starting point. Avoid reset, blanket staging, or a checkout that drops these changes.

The older `docs/plans/FEEDBACK_ROUND_2026-08-25.md` explains that work but does not replace this plan. Reset Microphone has separate prior feedback; this task does not expand into a microphone recovery redesign.

Record a baseline test result before implementation. Inspect test requirements before running suites that may use local models or hardware. Read-only code checks and automated tests need no new product approval. See the live-review boundary below before launching or controlling the app.

Completion: establish the starting changes and test status without altering existing work.

## 1. Diagnose and fix Add Feedback insertion

Read these paths first:

- `Sources/DictationKit/PasteboardTextInjector.swift`: synchronous `TextInjector` implementation, clipboard snapshots, injected paste keystroke, and 150 ms `Thread.sleep` before clipboard restoration.
- `Sources/whisper/main.swift`: injector construction and `addFeedback()`, which uses an `NSTextView` in `NSAlert.runModal()`.
- `Sources/DictationKit/Protocols.swift`: current injection contract.
- `Tests/DictationKitTests/PasteboardTextInjectorTests.swift`: fake clipboard and keystroke coverage.

The leading hypothesis is that self-directed Paste waits for the main thread, while the injector blocks that thread and restores the old clipboard before AppKit handles the event. This fits the report but is not yet a proven diagnosis. Use the diagnosing-bugs skill and a controlled regression to check it; existing fake-keystroke tests do not exercise AppKit event delivery.

Prefer a small, app-owned insertion route if evidence supports it: when Add Feedback is the active editable target at insertion time, insert through its normal text-editing API synchronously, with selection replacement, change notification, and Undo. Route other targets through the existing external injector. Keep routing at the app boundary, where window and responder identity are known, rather than putting AppKit target detection in `DictationController`.

Use positive target identity, not merely “whisper is frontmost.” A closed or unfocused feedback editor must not receive a late transcript. Do not activate a window to steal the target. Use weak or explicitly cleared target references so closing the editor cannot leave a stale destination. Preserve current target-at-insertion semantics rather than introducing a new target-capture policy.

For direct insertion, preserve the clipboard when restoration is enabled; when disabled, leave the transcript on the clipboard as the setting promises. An insertion failure must not report success or trigger a second insertion. If a direct route cannot meet these constraints, choose the smallest evidence-backed alternative and explain the tradeoff. Do not mask the suspected event-loop problem by increasing the sleep duration.

Completion: a regression proves the stale-clipboard failure mechanism or establishes another cause, the fix inserts the new transcript into the intended editor, and tests protect selected-text replacement, Undo, clipboard behavior, closed/unfocused target handling, and unchanged external routing. Exercise actual AppKit editing where needed; a mock that merely records `insert(text)` is insufficient proof of editor behavior.

## 2. Add a testable icon presentation model

Extend `Sources/DictationKit/MenuBarPresentation.swift` or add a focused adjacent type. Preserve the sound transition logic and its tests. Keep icon timing separate from the dictation state machine: transcription must not wait for a success animation to finish.

Consume both controller state transitions and outcomes. `DictationController.finish(_:)` currently calls `onOutcome` and then immediately sets `.idle`; that idle event must not erase the new result animation. `.transcribing` and `.injecting` share one continuous processing pulse. Initial `.idle` outcome produces no result animation.

Use a supplied monotonic time or clock for deterministic frame calculation. Represent logical appearance independently of AppKit, such as normal, recording, processing, success, failure, and no-speech with a start time. State/outcome handlers decide the appearance; a frame calculation decides the color mix at a given time. The app owns the redraw timer.

A new recording invalidates all older result deadlines. An old timer callback must never restore idle over a later recording, processing state, or result. Preserve current handling of all `.failed` outcomes, including interrupted live captures, unless a distinct existing outcome contract requires attention. File callbacks remain outside this icon model.

Completion: clock-driven tests cover the full behavior table, exact one/two/five-second boundaries, the brief flash, outcome-then-idle ordering, continuous processing across injection, new-recording interruption, repeated results, and stale callback protection. Existing sound tests still pass without added cues.

## 3. Render and connect the icon

Wire state updates from `render(_:)` and outcomes from `report(_:)` in `Sources/whisper/main.swift`. Preserve existing status messages and `resumeAfterLiveDictation()` behavior.

Use the bundled waveform as an immutable mask; retain its normal template rendering for idle. Render active colors without allowing template tinting to erase them, and blend success back to the normal appearance. Keep backing scale, image size, fallback waveform, and menu interaction intact. Update accessibility text or tooltip to name the current state without rapid announcements on every frame.

Drive animations on the main actor with one bounded redraw mechanism using elapsed time, rather than independent delayed closures for each phase. It must work while the menu or Add Feedback modal loop is open, stop when a static state is reached, and clean up at termination. Avoid per-frame resource loading or image allocation where practical; a small cached set or reusable renderer is sufficient.

Completion: the real app wiring consumes outcomes once, preserves animations through controller idle, and leaves file progress and sounds unchanged. Rendering supports both menu-bar appearances and normal/Retina scale. Automated tests check logical frames and integration; live appearance remains a separate acceptance step.

## 4. Update docs and run focused checks

Update `CONTEXT.md` with the settled icon behavior and Add Feedback insertion contract using the domain-modeling skill. Tell the user that it changed. Remove or replace directly conflicting claims that the same icon serves all states; avoid unrelated historical cleanup. Keep this plan current if implementation differs from its proposed structure.

Run the relevant presentation, controller, clipboard, and new editor/routing tests, then the appropriate full automated suite. Run `scripts/bundle.sh` to build the signed `.app` and check its signature/resources, without launching or replacing the running app. Use the existing stable signing identity; never use `swift run` for acceptance testing. Report baseline failures separately from regressions. Audio WER evaluation is only needed if the implementation changes audio or transcription behavior.

Completion: focused regressions and the appropriate suite pass, the signed bundle builds, and the report lists changes, test results, and remaining live checks. Do not claim live acceptance from pure-model tests.

## Live-review boundary and checklist

The user requires explicit permission before signed-app, UI, or hardware acceptance testing after changes. Finish implementation and automated checks first, then provide this focused checklist and ask for permission to test, or let the user perform it. Never send global test keystrokes or use coordinate automation where another app can receive them. If safe app-scoped controls cannot perform a step, ask the user to perform it.

1. Put distinctive old text on the clipboard, open Add Feedback, dictate different words, and check that only the new transcript appears at the cursor. Repeat with a selection, use Undo, check ordinary Paste, and check Save/Cancel. Check both clipboard settings. Use a disposable log target for automated tests; preserve real feedback entries.
2. Dictate into an external editor and check text insertion and clipboard restoration. Move focus away from Add Feedback before completion and check that the inactive editor does not receive the result.
3. Check red during capture, yellow through processing, then one second green plus a one-second fade to the visible normal icon. Check light and dark menu-bar appearances without changing the user's system appearance unless authorized.
4. Check one silent orange flash for a sub-0.5-second capture and for a no-speech result. Check the five-second orange failure animation through a controlled failure that does not revoke user permissions or damage the model installation.
5. Start a new recording during green, its fade, and orange; check immediate red and no later stale reset. Open the menu and Add Feedback while animations run to check timer behavior.
6. Run file transcription, interrupt it with live dictation, and check that file progress stays in the menu while live recording owns the icon and file work resumes afterward.

Completion: report which live checks the user or authorized agent completed and any remaining failures. Keep unapproved live checks explicitly pending. Commit or publish only when separately requested; preserve unrelated work in any later commit.
