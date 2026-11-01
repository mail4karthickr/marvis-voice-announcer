# WFFargoMarvisVoice's pinned MLXAudio dependency

Upstream: https://github.com/Blaizzy/mlx-audio-swift

Base revision: `3e978558404df4ad1bbb0a5634a03df2b0f9dfa5`.
This local source snapshot is the dependency used by both `project.yml` and the
checked-in Xcode project. Keep the upstream license and this file when updating.
The ignored `vendor/` and Xcode's package checkout are not build inputs.

Local changes:

1. `Mimi.resetState()` resets the downsampler and upsampler as well as the
   encoder, decoder, and attention caches. Reference recordings otherwise inherit
   convolution history from earlier phrases. `MimiResetTests` covers both paths.
2. `MarvisTTSModel` caches evaluated preset reference tokens, masks, and transcript
   per model instance/voice. Target text is still tokenized separately each time.
   Custom reference audio remains uncached. `prepare(voice:)` warms the selected
   preset; callers must serialize preparation and generation.
3. Sampling uses temperature `0.9`, top-k `50`, and no top-p filter, matching the
   [MLX Python reference](https://github.com/Blaizzy/mlx-audio/blob/main/mlx_audio/tts/models/sesame/sesame.py).
   The generic `SpeechGenerationModel` parameter overrides remain unsupported by
   this upstream Marvis implementation; app calls use its dedicated streaming API.

Build the app with Xcode in **Release** for realistic inference performance.
Plain `swift test` does not build the required Metal shader bundle.
4. `MarvisTTSModel.generate` serializes generations on the model instance. Each
   generation task first awaits the previous one, because a cancelled generation
   can still be finishing a frame while `WFFargoMarvisVoice` starts the next one
   on the same KV caches and Mimi streaming state. The caller therefore keeps the
   loaded model across interrupted utterances instead of dropping and reloading
   it (several seconds and a transient double memory footprint per interruption).
   The task also finishes its stream when the model has been deallocated, so a
   consumer never waits on a stream that nothing will complete.
5. `MarvisTTSModel.generate` takes an optional `maxAudioSeconds` (default 60, the
   previous fixed limit). The model sometimes misses its end-of-speech frame and
   keeps producing noise until the limit; `WFFargoMarvisVoice` bounds each piece to
   a few times its expected spoken length. The prompt-length precondition still
   uses the absolute 60 s limit so the context budget is unchanged.
6. `ModelUtils.resolveOrDownloadModel` and `Mimi.fromPretrained` verify cached
   safetensors files against their own headers (`ModelUtils.safetensorsIsComplete`).
   An interrupted download left a 150 MB `model.safetensors` (published size 665 MB)
   on a device; it existed, loaded without error and produced noise instead of speech
   until the file was replaced. Incomplete weights are now cleared and downloaded again.

7. `MarvisTTSModel.memoryReport()` and `MarvisTTSModel.releaseCachedMemory()` expose
   MLX memory figures and cache release, so the `WFFargoMarvisVoice` package can report and
   trim MLX memory without declaring its own dependency on `mlx-swift`.

Dependency ranges in `Package.swift` are the upstream ones (`mlx-swift` from 0.30.6,
`mlx-swift-lm` from 3.31.3, both `upToNextMajor`). The snapshot is known to compile
against mlx-swift 0.31.4 and mlx-swift-lm 3.31.4, which the checked-in
`Package.resolved` files pin. mlx-swift-lm 3.32 changes `makePromptCache` to throw and
breaks `CSMModel`/`SparkModel`; if a re-resolution moves there, restore the pins.
