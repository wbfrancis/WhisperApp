# Live dictation chunking design

## Goal

Reduce the delay after key release for long dictation by transcribing completed audio while recording continues. Keep one final insertion, so the destination receives stable text once and existing clipboard and Add Feedback rules remain intact.

This is a design proposal, not an implemented or approved behavior change.

## Current constraints

- `AVAudioEngineAudioSource` keeps all 16 kHz samples in one buffer and exposes them only through `stopCapture()`.
- `DictationController` starts one `transcribe(_:)` call after release and inserts one normalized result.
- `LocalWhisperEngine` owns one resident whisper context behind `SerialTranscriptionExecutor`; live and file work cannot run together.
- The current live profile clears decoder context and forces one segment. Each call still pays the roughly 850 ms encoder floor measured in the project prototype.
- File transcription already supplies the useful boundaries: bounded overlapping chunks, cooperative preemption, and `TranscriptOverlapMerge`.

The official whisper.cpp streaming example uses a rolling audio window with a step, a longer retained window, and audio kept across steps. It describes itself as a proof of concept, so its defaults are a starting point rather than a production contract: [whisper.cpp stream example](https://github.com/ggml-org/whisper.cpp/blob/master/examples/stream/stream.cpp). The public API exposes `no_context`, `single_segment`, `audio_ctx`, timestamps, and prompt limits needed for controlled experiments: [whisper.cpp API](https://github.com/ggml-org/whisper.cpp/blob/master/include/whisper.h).

## Recommended first version

1. **Snapshot without draining.** Extend the audio source with a recording-session stream that publishes immutable sample ranges. The realtime tap must only append; copying and scheduling stay off its thread.
2. **Start after five seconds.** Submit a six-second window after five seconds of unique speech, with one second of left overlap. Repeat every five seconds only when the prior job finishes, so inference never falls behind capture.
3. **Commit text internally.** Transcribe each completed window with `no_context = true`, then merge it with `TranscriptOverlapMerge`. Do not paste partial text while the key remains down.
4. **Finish the tail on release.** Wait for the active window, transcribe only the remaining samples plus overlap, merge the result, normalize once, and insert once. Dictation under five seconds follows the current path.
5. **Discard one session together.** A microphone change, reset, transcription failure, or cancellation drops its queued samples and partial text. A session identifier prevents old chunk callbacks from reaching a later recording.
6. **Keep file priority rules.** Live recording pauses file transcription before the first live chunk. File work resumes only after the final live insertion or failure.

Five seconds is the initial tuning point. It gives the roughly one-second model call enough time to finish before the next window, while bounding release work to about six seconds of audio. Short dictation keeps its present latency because the model's fixed encoder cost remains.

## Why partial insertion waits

Visible partial insertion would need to replace earlier guesses as context changes. Add Feedback can do that through `NSTextView`, but external apps only expose a synthesized paste, with no reliable range ownership or rollback. One final insertion keeps target-at-insertion semantics and avoids corrupting text that the user edits during recording.

If visible partials become a separate goal, restrict the first prototype to Add Feedback or an app-owned floating preview. Do not send provisional text into arbitrary external editors.

## Checks before release

- Unit-test window ranges, one-second overlap, slow-worker backpressure, release during a running chunk, session cancellation, and stale callback rejection.
- Reuse overlap tests with punctuation and repeated boundary phrases.
- Add long speech fixtures with pauses on both sides of chunk boundaries and compare normalized WER against the single-batch path.
- Measure key-release-to-insertion latency for 3, 8, 20, and 60-second utterances. The long cases must improve without a material WER regression.
- Check that file transcription pauses before live work and resumes after the final outcome.
