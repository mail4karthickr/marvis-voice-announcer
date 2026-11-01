import Foundation
import Observation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Expressive on-device speech for text and streamed Foundation Models replies.
///
/// Drop the `Marvis` folder into an iOS 17 app target that links the `MLXAudioTTS`
/// product of mlx-audio-swift. Everything else in the folder is an implementation detail.
/// Only the Foundation Models convenience overload needs iOS 26.
///
///     let marvis = Marvis()
///     try await marvis.speak("Hello there.")
///
///     let session = LanguageModelSession()
///     try await marvis.speak(session.streamResponse(to: "Tell me a fun fact")) { text in
///         reply = text   // the reply so far, for display
///     }
///
/// Each `speak` call returns after the last sample has played. Starting a new one,
/// calling `stop()`, or cancelling the calling task interrupts the current speech.
/// What to protect when the device cannot generate full-quality speech in real time.
public enum MarvisSpeechPriority: Sendable {
    /// Keep the full voice and let playback pause briefly to catch up. Fewer codebooks make the voice
    /// slower and weaker, which listeners notice more than an occasional pause.
    case fidelity
    /// Keep speech flowing and accept the thinner voice of fewer codebooks as soon as generation lags.
    case continuity
}

@MainActor @Observable
public final class Marvis {
    public enum Voice: Sendable {
        case conversationalA
        case conversationalB
    }

    /// How each element of a text stream relates to the previous one.
    public enum StreamFormat: Sendable {
        /// Each element is the whole reply so far, as Foundation Models snapshots are.
        case cumulative
        /// Each element is new text to append, such as token deltas.
        case incremental
    }

    public var voice: Voice
    /// Trade-off applied when generation cannot keep up with playback. Takes effect from the next `speak`.
    public var speechPriority: MarvisSpeechPriority
    /// True once the model has been downloaded and loaded into memory.
    public private(set) var isPrepared = false
    public private(set) var isSpeaking = false
    /// Called once per `speak` when its first audio reaches the speaker.
    @ObservationIgnored public var onPlaybackStart: (@MainActor () -> Void)?
    /// Receives one line per notable event: model load, per-piece generation speed, quality changes,
    /// player underruns and rebuffering, audio engine or session changes, MLX memory. The same lines go to
    /// the unified log under subsystem `MarvisVoice`. One sink is shared by all instances.
    @ObservationIgnored public var onDiagnostic: (@Sendable (String) -> Void)? {
        didSet { MarvisDiagnostics.setSink(onDiagnostic) }
    }
    /// Receives every PCM chunk (mono Float32 and its sample rate) as it is queued for playback, for
    /// recording or analysis. Called off the main thread. One tap is shared by all instances.
    @ObservationIgnored public var audioTap: (@Sendable ([Float], Int) -> Void)? {
        didSet { MarvisDiagnostics.setAudioSink(audioTap) }
    }

    @ObservationIgnored private let synthesizer = MarvisSynthesizer.shared
    @ObservationIgnored private let player: MarvisPCMPlayer
    @ObservationIgnored private var current: Task<Void, Error>?
    @ObservationIgnored private var currentID = UUID()
    @ObservationIgnored private var utterance: UUID?
    @ObservationIgnored private var playback: (id: UUID, continuation: CheckedContinuation<Void, Error>)?
    /// Player stops run on the player's executor. They are chained and awaited before the next utterance
    /// begins, so a stale stop can never land on a freshly started one.
    @ObservationIgnored private var pendingStop: Task<Void, Never>?

    /// - Parameters:
    ///   - voice: The preset voice to speak with.
    ///   - managesAudioSession: Configure and activate the shared audio session for playback and
    ///     deactivate it afterwards. Pass `false` when the host owns the session, for example around a
    ///     speech recognizer, and Marvis should only play through whatever is configured.
    ///   - speechPriority: What to protect when the device falls behind real time; see `MarvisSpeechPriority`.
    public init(
        voice: Voice = .conversationalA,
        managesAudioSession: Bool = true,
        speechPriority: MarvisSpeechPriority = .fidelity
    ) {
        self.voice = voice
        self.speechPriority = speechPriority
        var configuration = MarvisPCMPlayer.Configuration()
        configuration.managesAudioSession = managesAudioSession
        self.player = MarvisPCMPlayer(configuration: configuration)
    }

    /// Downloads the model on first use (about 250 MB) and loads it. Optional, since
    /// `speak` loads on demand, but calling it early keeps loading out of the first reply.
    public func prepare() async throws {
        try await synthesizer.prepare(voiceB: voice == .conversationalB)
        isPrepared = true
    }

    /// Speaks a complete piece of text.
    public func speak(_ text: String) async throws {
        try await perform {
            let (phrases, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            continuation.yield(text)
            continuation.finish()
            try await self.synthesize(phrases)
        }
    }

    /// Speaks a streamed reply while it is still being generated.
    /// `onText` receives the full reply so far each time the stream advances.
    public func speak<Text: AsyncSequence>(
        _ stream: Text,
        format: StreamFormat = .cumulative,
        onText: (@MainActor (String) -> Void)? = nil
    ) async throws where Text.Element == String {
        try await perform {
            try await MarvisStreamingReply.run(
                style: .natural,
                generate: { receive in
                    var reply = ""
                    for try await element in stream {
                        reply = format == .cumulative ? element : reply + element
                        onText?(reply)
                        receive(reply)
                    }
                },
                speak: { phrases in try await self.synthesize(phrases) }
            )
        }
    }

    #if canImport(FoundationModels)
    /// Speaks a Foundation Models reply as it streams: pass `session.streamResponse(to:)` directly.
    @available(iOS 26.0, *)
    public func speak(
        _ response: LanguageModelSession.ResponseStream<String>,
        onText: (@MainActor (String) -> Void)? = nil
    ) async throws {
        try await speak(response.map { $0.content }, format: .cumulative, onText: onText)
    }
    #endif

    /// Stops generation and playback immediately. The interrupted `speak` throws `CancellationError`.
    public func stop() {
        current?.cancel()
        stopPlayer()
        if let playback {
            self.playback = nil
            playback.continuation.resume(throwing: CancellationError())
        }
        isSpeaking = false
    }

    private func stopPlayer() {
        let player = self.player
        let previous = pendingStop
        pendingStop = Task(priority: .userInitiated) {
            await previous?.value
            await player.stop()
        }
    }

    private func perform(_ body: @escaping @MainActor () async throws -> Void) async throws {
        // The synthesizer serves one utterance at a time, so let the previous one unwind first.
        while let previous = current {
            stop()
            _ = await previous.result
        }
        try Task.checkCancellation()
        let id = UUID()
        currentID = id
        isSpeaking = true
        // Speech is interactive: a host that calls from a background queue must not demote generation.
        let task = Task(priority: .userInitiated) {
            defer {
                if self.currentID == id {
                    self.current = nil
                    self.isSpeaking = false
                }
            }
            do {
                if let pendingStop = self.pendingStop {
                    await pendingStop.value
                }
                let token = await self.player.begin()
                self.utterance = token
                try await body()
                try Task.checkCancellation()
                try await self.waitForPlayback(token)
            } catch {
                if self.currentID == id { self.stopPlayer() }
                throw error
            }
        }
        current = task
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func synthesize(_ phrases: AsyncThrowingStream<String, Error>) async throws {
        guard let utterance else { throw MarvisError.message("Playback was not started.") }
        try await synthesizer.speak(
            phrases, voiceB: voice == .conversationalB, priority: speechPriority, player: player, utterance: utterance
        ) { [weak self] in
            await self?.playbackDidStart()
        }
        isPrepared = true
    }

    private func playbackDidStart() {
        onPlaybackStart?()
    }

    private func waitForPlayback(_ token: UUID) async throws {
        let id = UUID()
        let player = self.player
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                playback = (id, continuation)
                Task { @MainActor [weak self] in
                    await player.finish(utterance: token) {
                        Task { @MainActor in self?.endPlayback(id, throwing: nil) }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.endPlayback(id, throwing: CancellationError()) }
        }
    }

    private func endPlayback(_ id: UUID, throwing error: Error?) {
        guard let playback, playback.id == id else { return }
        self.playback = nil
        if let error {
            stopPlayer()
            playback.continuation.resume(throwing: error)
        } else {
            playback.continuation.resume()
        }
    }
}
