import Foundation
@preconcurrency import MLXAudioTTS

/// A single owner serializes access to the mutable Marvis model and codec caches, and adapts generation
/// cost to what the device can sustain.
actor MarvisSynthesizer {
    /// The model and codec are large; every caller in the process shares one loaded copy.
    static let shared = MarvisSynthesizer()
    static let modelID = "Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit"

    /// Highest quality used. `.maximum` (32 codebooks) could not sustain real time on the devices this was
    /// tuned on; `.high` (24) keeps pace on an otherwise idle device and is the level the controller climbs
    /// back to when there is headroom.
    static let qualityCeiling = MarvisTTSModel.QualityLevel.high
    /// Lowest quality used. At 8 codebooks the frames fed back into the backbone carry a quarter of the
    /// codebook embeddings it was trained on and generation becomes erratic (device tests produced 8 s of
    /// audio for a 42-character sentence and 33 s for a 176-character one). 16 keeps it stable.
    static let qualityFloor = MarvisTTSModel.QualityLevel.medium
    /// Generated audio waiting to be played is held in memory. Pause generation when this much is waiting.
    static let maximumLeadSeconds = 45.0
    /// Mimi produces 12.5 frames per second; two frames per chunk keeps first-audio latency low.
    static let streamingInterval = 0.16
    private struct Thresholds {
        /// Effective real-time factor above which a quality level is shed.
        let shed: Double
        /// Effective real-time factor below which a level is restored. Kept below `shed` times the cost
        /// ratio of neighbouring levels (about 0.7), so the controller settles instead of flapping.
        let restore: Double
    }

    /// Fewer codebooks change the speech itself: on device, 16 codebooks stretched the same paragraph from
    /// 48 s to 60-66 s and made it sound weak. With `.fidelity` a level is shed only when playback would
    /// otherwise pause for a good part of the time; with `.continuity` as soon as generation falls behind
    /// real time. A device reporting thermal pressure is about to be throttled, so it sheds a little earlier.
    private static func thresholds(for priority: MarvisSpeechPriority, hot: Bool) -> Thresholds {
        switch (priority, hot) {
        case (.fidelity, false): Thresholds(shed: 1.35, restore: 0.85)
        case (.fidelity, true): Thresholds(shed: 1.25, restore: 0.80)
        case (.continuity, false): Thresholds(shed: 1.0, restore: 0.65)
        case (.continuity, true): Thresholds(shed: 0.95, restore: 0.60)
        }
    }
    /// Chunks observed at a quality level before the controller judges it again.
    static let settleChunks = 6
    /// With fewer codebooks the frames fed back to the backbone are off-distribution and end-of-speech
    /// timing drifts over long generations: on device the same 176-character sentence took 7 s, 14 s and
    /// 18 s at 16 codebooks against a steady 10 s at 24. Short pieces keep each generation on track.
    static let reducedQualityPieceLimit = 100

    private var model: MarvisTTSModel?
    private var loading: Task<MarvisTTSModel, Error>?
    private var busy = false
    private var quality = MarvisSynthesizer.qualityCeiling
    private var priority = MarvisSpeechPriority.fidelity
    private var chunksSinceQualityChange = 0
    private var piecesSinceQualityChange = 0
    /// Smoothed real-time factor of steady-state generation (seconds of work per second of audio), measured
    /// on chunks after the first of each piece. Sizes the player's buffers. Persists across utterances
    /// because device speed does.
    private(set) var steadyRTF: Double?
    /// Smoothed real-time factor of whole pieces, prompt prefill included. On a hot device the prefill at
    /// each piece boundary doubles, so this is what decides whether generation keeps pace.
    private(set) var effectiveRTF: Double?

    func prepare(voiceB: Bool = false) async throws {
        try await acquire()
        defer { busy = false }
        let model = try await load()
        let started = ContinuousClock.now
        try model.prepare(voice: voiceB ? .conversationalB : .conversationalA)
        let elapsed = MarvisDiagnostics.toSeconds(started.duration(to: .now))
        MarvisDiagnostics.log("voice prepared in \(MarvisDiagnostics.seconds(elapsed)), \(memoryDescription)")
    }

    func speak(
        _ phrases: AsyncThrowingStream<String, Error>,
        voiceB: Bool,
        priority: MarvisSpeechPriority,
        player: MarvisPCMPlayer,
        utterance: UUID,
        onFirstAudio: @escaping @Sendable () async -> Void
    ) async throws {
        try await acquire()
        self.priority = priority
        defer {
            busy = false
            // Hand MLX's recycled buffers back between utterances. A memory-constrained host gets up to the
            // cache limit (100 MB) back, and the next utterance re-warms the cache within a few frames.
            MarvisTTSModel.releaseCachedMemory()
        }
        let model = try await load()
        let voice: MarvisTTSModel.Voice = voiceB ? .conversationalB : .conversationalA
        let statisticsBefore = await player.statistics
        let utteranceStart = ContinuousClock.now
        let startQuality = quality
        var pieceCount = 0
        var audioSeconds = 0.0
        var firstAudio: Double?

        for try await phrase in phrases {
            for sentence in MarvisSpeechText.chunks(phrase) {
                try Task.checkCancellation()
                try await player.waitUntilQueued(below: Self.maximumLeadSeconds)
                let level = nextQuality()
                let pieces = level.index < Self.qualityCeiling.index
                    ? MarvisSpeechText.chunks(sentence, limit: Self.reducedQualityPieceLimit)
                    : [sentence]
                for piece in pieces {
                    try Task.checkCancellation()
                    pieceCount += 1
                    let pieceStart = ContinuousClock.now
                    var chunks = 0
                    var pieceAudio = 0.0
                    var pieceRTFs: [Double] = []
                    var firstChunk = 0.0
                    // Speech runs at roughly 17 characters per second. When the model misses its end-of-speech
                    // frame it babbles for up to 60 s; stop it at a few times the expected length instead.
                    // Spelled-out acronyms are slow, so the allowance stays generous.
                    let maxAudioSeconds = min(60, 3 + Double(piece.count) * 0.12)
                    let stream = model.generate(
                        text: piece,
                        voice: voice,
                        qualityLevel: level,
                        streamingInterval: Self.streamingInterval,
                        maxAudioSeconds: maxAudioSeconds
                    )
                    for try await chunk in stream {
                        try Task.checkCancellation()
                        chunks += 1
                        pieceAudio += chunk.audioDuration
                        if chunks == 1 {
                            // Includes the prompt prefill: the reference recording plus the text run through
                            // the backbone before the first frame. This is the stall every piece boundary costs.
                            firstChunk = MarvisDiagnostics.toSeconds(pieceStart.duration(to: .now))
                        } else {
                            observe(rtf: chunk.realTimeFactor)
                            pieceRTFs.append(chunk.realTimeFactor)
                        }
                        var samples = chunk.audio
                        MarvisPeakLimiter.limit(&samples)
                        MarvisDiagnostics.tap(samples, sampleRate: chunk.sampleRate)
                        try await player.enqueue(
                            MarvisPCMChunk(samples: samples, sampleRate: chunk.sampleRate, expectedRTF: steadyRTF),
                            utterance: utterance
                        )
                        if firstAudio == nil {
                            firstAudio = MarvisDiagnostics.toSeconds(utteranceStart.duration(to: .now))
                            await onFirstAudio()
                        }
                    }
                    audioSeconds += pieceAudio
                    let pieceSeconds = MarvisDiagnostics.toSeconds(pieceStart.duration(to: .now))
                    observePiece(audio: pieceAudio, seconds: pieceSeconds)
                    MarvisDiagnostics.log(
                        "piece \(pieceCount): \(piece.count) chars → \(MarvisDiagnostics.seconds(pieceAudio)) audio in "
                        + "\(MarvisDiagnostics.seconds(pieceSeconds)), first chunk after \(MarvisDiagnostics.seconds(firstChunk)), "
                        + "steady rtf \(Self.format(pieceRTFs.mean)), \(level.label), "
                        + "thermal \(Self.describe(ProcessInfo.processInfo.thermalState))")
                }
            }
        }
        try Task.checkCancellation()

        let statisticsAfter = await player.statistics
        let elapsed = MarvisDiagnostics.toSeconds(utteranceStart.duration(to: .now))
        let overall = audioSeconds > 0 ? elapsed / audioSeconds : 0
        MarvisDiagnostics.log(
            "utterance: \(pieceCount) pieces, \(MarvisDiagnostics.seconds(audioSeconds)) audio generated in "
            + "\(MarvisDiagnostics.seconds(elapsed)) (overall rtf \(Self.format(overall))), first audio "
            + "\(firstAudio.map(MarvisDiagnostics.seconds) ?? "never"), underruns "
            + "\(statisticsAfter.underruns - statisticsBefore.underruns), rebuffering "
            + "\(MarvisDiagnostics.seconds(statisticsAfter.rebufferTime - statisticsBefore.rebufferTime)), "
            + "quality \(startQuality.label) → \(quality.label), \(memoryDescription)")
    }

    // MARK: Loading

    /// Waits for a running `prepare` or `speak` to finish rather than failing: an announcement that arrives
    /// while the model is still loading must not be dropped. The bound only covers a first-run download.
    private func acquire() async throws {
        let deadline = ContinuousClock.now + .seconds(600)
        while busy {
            guard ContinuousClock.now < deadline else {
                throw MarvisError.message("The voice engine is still busy. Try again shortly.")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        busy = true
    }

    /// Loads once per process. The model stays loaded across interrupted utterances; the vendored
    /// `MarvisTTSModel` serializes generations, so a cancelled one cannot corrupt the next.
    private func load() async throws -> MarvisTTSModel {
        if let model { return model }
        let task: Task<MarvisTTSModel, Error>
        if let loading {
            task = loading
        } else {
            let started = ContinuousClock.now
            task = Task(priority: .userInitiated) {
                let loaded = try await MarvisTTSModel.fromPretrained(Self.modelID)
                let elapsed = MarvisDiagnostics.toSeconds(started.duration(to: .now))
                MarvisDiagnostics.log("model loaded in \(MarvisDiagnostics.seconds(elapsed))")
                return loaded
            }
            loading = task
        }
        do {
            let loaded = try await task.value
            if model == nil {
                model = loaded
                loading = nil
                MarvisDiagnostics.log("after load: \(memoryDescription)")
            }
            try Task.checkCancellation()
            return loaded
        } catch {
            loading = nil
            throw error
        }
    }

    private var memoryDescription: String {
        let report = MarvisTTSModel.memoryReport()
        return "MLX active \(MarvisDiagnostics.megabytes(report.active)), "
            + "cache \(MarvisDiagnostics.megabytes(report.cache)), "
            + "peak \(MarvisDiagnostics.megabytes(report.peak))"
    }

    // MARK: Adaptive quality

    private func observe(rtf: Double) {
        guard rtf.isFinite, rtf > 0 else { return }
        steadyRTF = steadyRTF.map { 0.7 * $0 + 0.3 * rtf } ?? rtf
        chunksSinceQualityChange += 1
    }

    private func observePiece(audio: Double, seconds: Double) {
        guard audio >= 1, seconds > 0 else { return }
        let ratio = seconds / audio
        effectiveRTF = effectiveRTF.map { 0.5 * $0 + 0.5 * ratio } ?? ratio
        piecesSinceQualityChange += 1
    }

    /// Chooses the codebook count for the next piece. Each codebook is one depth-decoder pass per frame, so
    /// shedding levels is the main lever when the device cannot keep up. Thermal pressure caps the level
    /// pre-emptively because throttling is about to raise the real-time factor anyway.
    private func nextQuality() -> MarvisTTSModel.QualityLevel {
        let thermal = ProcessInfo.processInfo.thermalState
        let hot = thermal == .serious || thermal == .critical
        let thresholds = Self.thresholds(for: priority, hot: hot)
        let shedRTF = thresholds.shed
        let restoreRTF = thresholds.restore
        var ceiling = Self.qualityCeiling
        if thermal == .critical { ceiling = ceiling.capped(at: Self.qualityFloor) }
        var next = quality
        if let rtf = effectiveRTF, piecesSinceQualityChange >= 1, chunksSinceQualityChange >= Self.settleChunks {
            if rtf > shedRTF {
                next = quality.lower
            } else if rtf < restoreRTF {
                next = quality.higher
            }
        }
        next = next.capped(at: ceiling).raised(to: Self.qualityFloor)
        if next != quality {
            let rtf = effectiveRTF.map(Self.format) ?? "unknown"
            MarvisDiagnostics.log("quality \(quality.label) → \(next.label) (effective rtf \(rtf), thermal \(Self.describe(thermal)))")
            quality = next
            chunksSinceQualityChange = 0
            piecesSinceQualityChange = 0
        }
        return quality
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

private extension MarvisTTSModel.QualityLevel {
    static let ordered: [MarvisTTSModel.QualityLevel] = [.low, .medium, .high, .maximum]

    var index: Int { Self.ordered.firstIndex(of: self) ?? 2 }
    var lower: Self { Self.ordered[max(0, index - 1)] }
    var higher: Self { Self.ordered[min(Self.ordered.count - 1, index + 1)] }
    var label: String { "\(rawValue) codebooks" }

    func capped(at ceiling: Self) -> Self {
        index > ceiling.index ? ceiling : self
    }

    func raised(to floor: Self) -> Self {
        index < floor.index ? floor : self
    }
}

private extension Array where Element == Double {
    var mean: Double { isEmpty ? 0 : reduce(0, +) / Double(count) }
}
