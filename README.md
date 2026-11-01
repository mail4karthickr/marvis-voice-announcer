# Marvis Voice Announcer

On-device neural text-to-speech for iOS built on [Marvis TTS](https://huggingface.co/Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit)
and MLX, packaged for a host app that announces replies and gates a speech recognizer on them.

## Layout

| Path | What it is |
|---|---|
| `Integrations/MarvisVoice` | The Swift package a host app links. Entry point: `MarvisAnnouncer`. |
| `Integrations/mlx-audio-swift` | Vendored snapshot of [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) with local patches, listed in `MARVIS_PATCHES.md`. `MarvisVoice` depends on it by relative path, so the two folders stay side by side. |
| `MarvisAudioTest` | Sample iOS app with a diagnostics panel and scripted test scenarios. |

## Using the package

```swift
import MarvisVoice

let announcer = MarvisAnnouncer()          // or MarvisAnnouncer(managesAudioSession: false, speechPriority: .continuity)
announcer.onDiagnostic = { line in print("[Marvis] \(line)") }
announcer.prewarm()                         // loads the model ahead of the first reply
announcer.announce(["Hello there."])        // replaces anything currently being spoken
```

`MarvisAnnouncer.queuedNotification` and `MarvisAnnouncer.finishedNotification` are posted when speech is
accepted and when the last sample has played; a host that runs a speech recognizer gates its microphone on them.
`audioTap` receives every PCM chunk for recording or analysis.

Requirements: iOS 17 (the Foundation Models convenience overload needs iOS 26), a Metal device (no simulator), about 1.2 GB of memory while speaking, roughly 1 GB of
model downloads on first use. Build in Release for realistic performance.

## What the package handles

- Playback pauses and rebuffers when generation falls behind instead of playing fragments with gaps.
- Quality adapts to measured generation speed (`speechPriority` chooses between full voice with occasional
  pauses and uninterrupted speech with a thinner voice).
- Audio engine configuration changes and session interruptions are survived; the finished notification is
  never left unposted.
- Generated audio is soft-limited below full scale, and runaway generation is capped per piece.
- Incomplete weight downloads are detected from the safetensors header and downloaded again.

## Test app scenarios

Launch `MarvisAudioTest` with `-scenario <name> -exitWhenDone` (`basic`, `stop`, `interrupt`, `rapid`,
`streaming`, `stress`, `stress-heavy`, `repeat5`). Every session writes `Documents/diagnostics.log` and one WAV
per utterance into the app container.
