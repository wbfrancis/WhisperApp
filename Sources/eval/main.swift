import Foundation
import DictationKit

// Offline transcription eval. Reads `<fixtures>/manifest.json` (an array of {file, expected}),
// transcribes each audio file through the real engine, and scores it against the expected
// text with word error rate (WER). Trim and pass/fail knobs come from the environment so
// the trim can be tuned without recompiling:
//
//   FIXTURES=fixtures            directory holding manifest.json + audio (default "fixtures")
//   WHISPER_MODEL=/path/model    model file (default: the app's Application Support copy)
//   TRIM=on|off                  apply silence trimming before transcription (default on)
//   TRIM_FLOOR=0.0025            SilenceTrim absoluteFloor
//   TRIM_FRACTION=0.12           SilenceTrim relativeFraction
//   TRIM_PAD_MS=300              SilenceTrim trailing pad, milliseconds
//   THRESHOLD=0.2                mean-WER above which the run exits nonzero

struct Fixture: Decodable {
    let file: String
    let expected: String
}

func env(_ key: String) -> String? {
    ProcessInfo.processInfo.environment[key]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("eval: \(message)\n".utf8))
    exit(2)
}

let fixturesDir = env("FIXTURES") ?? "fixtures"
let manifestURL = URL(fileURLWithPath: fixturesDir).appendingPathComponent("manifest.json")
guard let manifestData = try? Data(contentsOf: manifestURL) else {
    fail("no manifest at \(manifestURL.path)")
}
guard let fixtures = try? JSONDecoder().decode([Fixture].self, from: manifestData) else {
    fail("manifest at \(manifestURL.path) isn't a JSON array of {file, expected}")
}

let modelPath = env("WHISPER_MODEL") ?? WhisperModelStore().modelURL.path
guard FileManager.default.fileExists(atPath: modelPath) else {
    fail("model not found at \(modelPath); set WHISPER_MODEL")
}

let trimOn = (env("TRIM")?.lowercased()).map { !["off", "0", "false", "no"].contains($0) } ?? true
let floor = env("TRIM_FLOOR").flatMap(Float.init) ?? 0.0025
let fraction = env("TRIM_FRACTION").flatMap(Float.init) ?? 0.12
let padMS = env("TRIM_PAD_MS").flatMap(Int.init) ?? 300
let pad = padMS * 16  // 16 samples per ms at 16kHz
let threshold = env("THRESHOLD").flatMap(Double.init) ?? 0.2

let engine = LocalWhisperEngine(modelPath: modelPath)

func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }

print("eval: \(fixtures.count) fixture(s), trim \(trimOn ? "on (floor=\(floor), fraction=\(fraction), pad=\(padMS)ms)" : "off")\n")

var totalWER = 0.0
var worst = 0.0
var failures = 0

for fixture in fixtures {
    let audioURL = URL(fileURLWithPath: fixturesDir).appendingPathComponent(fixture.file)
    let got: String
    do {
        let raw = try AudioDecoding.samples16kMono(fromFile: audioURL)
        let samples = trimOn
            ? SilenceTrim.trimmingTrailingSilence(raw, absoluteFloor: floor, relativeFraction: fraction, pad: pad)
            : raw
        got = DeterministicTextNormalizer().normalize(try await engine.transcribeRaw(samples))
    } catch {
        print("✗ \(fixture.file)  ERROR \(error)")
        totalWER += 1
        worst = 1
        failures += 1
        continue
    }

    let wer = TranscriptionScore.wer(expected: fixture.expected, got: got)
    totalWER += wer
    worst = max(worst, wer)
    if wer > threshold { failures += 1 }

    let mark = wer <= threshold ? "✓" : "✗"
    print("\(mark) \(fixture.file)  WER \(pct(wer))")
    print("    expected: \(fixture.expected)")
    print("    got:      \(got)")
}

let meanWER = fixtures.isEmpty ? 0 : totalWER / Double(fixtures.count)
print("\nmean WER \(pct(meanWER))   worst \(pct(worst))   over-threshold \(failures)/\(fixtures.count)")

exit(meanWER > threshold ? 1 : 0)
