import Foundation
import Metal

/// Speaks text with the Marvis on-device neural voice (MLX).
///
/// Drives the same `Marvis` entry points as the Marvis demo, so the host app's voice speak-over and the demo share
/// one synthesis/playback path. The host registers this with its voice provider factory, and the conformance to the
/// host's announcer protocol is declared there, so this engine package stays independent of the host.
@MainActor
public final class MarvisAnnouncer {
    /// Posted when an announcement is accepted and when the last one has finished playing. A host that runs a
    /// speech recognizer gates its hands-free mic on these, so it does not tear Marvis down mid-reply. Keep them
    /// in sync with the host's system-voice announcer.
    public static let queuedNotification = Notification.Name("marvisSpeechAnnouncementQueued")
    public static let finishedNotification = Notification.Name("marvisSpeechAnnouncementFinished")

    private let marvis: Marvis
    private var didPrewarm = false
    private var activeCount = 0

    /// One line per notable event: model load time and memory, per-piece generation speed, quality changes,
    /// player underruns and rebuffering, audio engine or session changes. The same lines go to the unified
    /// log under subsystem `MarvisVoice`, category `Marvis`.
    public var onDiagnostic: (@Sendable (String) -> Void)? {
        get { marvis.onDiagnostic }
        set { marvis.onDiagnostic = newValue }
    }

    /// Every PCM chunk (mono Float32 plus sample rate) as it is queued for playback, for recording or
    /// analysis. Called off the main thread.
    public var audioTap: (@Sendable ([Float], Int) -> Void)? {
        get { marvis.audioTap }
        set { marvis.audioTap = newValue }
    }

    /// - Parameter managesAudioSession: Let Marvis set the shared audio session to playback when speech
    ///   starts and deactivate it when speech ends. Pass `false` if the host configures the session itself
    ///   around its speech recognizer and only wants Marvis to play through it.
    ///   - speechPriority: What to protect when the device cannot keep up: the full voice with occasional
    ///   pauses (`.fidelity`, default) or uninterrupted speech with a thinner voice (`.continuity`).
    public init(managesAudioSession: Bool = true, speechPriority: MarvisSpeechPriority = .fidelity) {
        marvis = Marvis(managesAudioSession: managesAudioSession, speechPriority: speechPriority)
    }

    /// Trade-off applied when generation cannot keep up with playback. Takes effect from the next announcement.
    public var speechPriority: MarvisSpeechPriority {
        get { marvis.speechPriority }
        set { marvis.speechPriority = newValue }
    }

    /// True from an accepted announcement until its last sample has played or it was stopped. The same
    /// span is bracketed by `queuedNotification` and `finishedNotification`.
    public var isSpeaking: Bool { marvis.isSpeaking }

    /// Marvis runs on the Metal GPU; it is unavailable on the simulator.
    public var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return MTLCreateSystemDefaultDevice() != nil
        #endif
    }

    /// Loads the Marvis model ahead of the first `announce` call. An announcement that arrives while loading
    /// is still in progress waits for it instead of being dropped.
    public func prewarm() {
        guard isAvailable, !didPrewarm else { return }
        didPrewarm = true
        let marvis = self.marvis
        Task(priority: .userInitiated) { try? await marvis.prepare() }
    }

    /// Speaks the given texts as one reply, replacing anything currently being spoken.
    public func announce(_ texts: [String]) {
        let sentences = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { text -> String in
                // End each text as a sentence without doubling punctuation that is already there.
                guard let last = text.last, ".!?;:,".contains(last) else { return text + "." }
                return text
            }
        let text = sentences.joined(separator: " ")
        guard isAvailable, !text.isEmpty else { return }
        speak { try await self.marvis.speak(text) }
    }

    /// Speaks cumulative model snapshots as they arrive, splitting them into phrases so the first words
    /// play before the full reply is generated.
    public func announce(streaming snapshots: AsyncThrowingStream<String, Error>) {
        guard isAvailable else { return }
        speak { try await self.marvis.speak(snapshots, format: .cumulative) }
    }

    /// Stops any Marvis speech in progress.
    public func stop() {
        marvis.stop()
    }

    /// Runs a `Marvis` speak call, replacing anything currently being spoken and swallowing cancellation.
    private func speak(_ body: @escaping @MainActor () async throws -> Void) {
        marvis.stop()
        postQueued()
        Task(priority: .userInitiated) { @MainActor [weak self] in
            defer { self?.postFinished() }
            do { try await body() }
            catch is CancellationError {}
            catch { MarvisDiagnostics.log("announce failed: \(MarvisDiagnostics.describe(error))") }
        }
    }

    /// Counting pair so overlapping speak calls still open and close exactly one bracket for listeners.
    private func postQueued() {
        activeCount += 1
        if activeCount == 1 {
            NotificationCenter.default.post(name: Self.queuedNotification, object: nil)
        }
    }

    private func postFinished() {
        activeCount -= 1
        if activeCount == 0 {
            NotificationCenter.default.post(name: Self.finishedNotification, object: nil)
        }
    }
}
