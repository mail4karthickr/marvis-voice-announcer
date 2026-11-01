import AVFoundation
import Foundation

/// One chunk of generated speech on its way to the speaker.
struct MarvisPCMChunk: Sendable {
    let samples: [Float]
    let sampleRate: Int
    /// Smoothed steady-state generation real-time factor (seconds of work per second of audio), once known.
    let expectedRTF: Double?
}

/// Marvis output occasionally exceeds full scale: device recordings showed two to four peaks per second at
/// or above 0 dBFS, which the speaker's converter clips into audible crackle. A soft knee above `threshold`
/// maps any overshoot smoothly into the remaining headroom. It is stateless, so it adds no latency and
/// leaves everything below the threshold untouched.
enum MarvisPeakLimiter {
    static let threshold: Float = 0.85

    static func limit(_ samples: inout [Float]) {
        let threshold = Self.threshold
        let headroom = 1 - threshold
        for index in samples.indices {
            let sample = samples[index]
            let magnitude = abs(sample)
            guard magnitude > threshold else { continue }
            let limited = threshold + headroom * tanh((magnitude - threshold) / headroom)
            samples[index] = sample < 0 ? -limited : limited
        }
    }
}

/// Streams PCM into an `AVAudioPlayerNode` and keeps speech intelligible when generation falls behind.
///
/// When generation is slower than real time the node used to run dry and then play each 160 ms chunk the
/// moment it arrived, with silence in between: crackly, weak, unintelligible speech. This player pauses
/// when the queue runs low and resumes once enough audio is buffered again, so the listener hears a short
/// pause followed by clean speech. It sizes the initial buffer from the measured generation speed, survives
/// engine configuration changes and session interruptions caused by other audio users in the process, and
/// bounds how long `finish` can wait, so a host that gates its microphone on the end of speech is never
/// left waiting.
///
/// It is an actor with its own executor: feeding the speaker must not depend on a busy main thread.
actor MarvisPCMPlayer {
    struct Configuration: Sendable {
        /// Set the shared `AVAudioSession` category when playback starts and deactivate it when it ends.
        /// Hosts that manage the session themselves, for example around a speech recognizer, can turn this off.
        var managesAudioSession = true
        /// Audio buffered before playback starts while generation speed is still unknown.
        var initialPrebufferSeconds = 0.6
        /// Audio buffered before playback resumes after the queue ran low. Grows with repeated underruns.
        var rebufferSeconds = 1.0
        var maximumRebufferSeconds = 3.0
        /// Playback pauses to rebuffer when less than this is queued (about one 160 ms chunk).
        var lowWaterSeconds = 0.25
    }

    struct Statistics: Sendable {
        var underruns = 0
        var rebufferTime: TimeInterval = 0
        var configurationChanges = 0
        var interruptions = 0
        var forcedDrains = 0
    }

    private let configuration: Configuration
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    /// True when this player set the session category itself. A session the host configured (for
    /// example `.playAndRecord` around a speech recognizer) is used as found and never deactivated.
    private var sessionOwned = false
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    /// Identifies the utterance being played; chunks and completions from a stopped utterance are ignored.
    private var utterance = UUID()
    private var queuedSamples = 0
    private var finished = false
    private var playbackStarted = false
    private var rebuffering = false
    private var interrupted = false
    private var rebufferTarget = 0
    private var underruns = 0
    private var rebufferStartedAt: ContinuousClock.Instant?
    private var expectedRTF: Double?
    private var lastProgress = ContinuousClock.now
    private var onDrained: (@Sendable () -> Void)?
    private var drainWatchdog: Task<Void, Never>?
    private(set) var statistics = Statistics()

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        engine.attach(node)
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Utterance lifecycle

    /// Starts a new utterance, stopping any previous one, and returns the token that identifies it.
    func begin() -> UUID {
        if format != nil || queuedSamples > 0 || onDrained != nil { stop() }
        let token = UUID()
        utterance = token
        return token
    }

    func enqueue(_ chunk: MarvisPCMChunk, utterance token: UUID) async throws {
        guard token == utterance else { throw CancellationError() }
        guard !chunk.samples.isEmpty else { return }
        try Task.checkCancellation()
        if let rtf = chunk.expectedRTF { expectedRTF = rtf }
        if format == nil { try await start(sampleRate: chunk.sampleRate) }
        guard let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw MarvisError.message("Could not allocate an audio buffer.")
        }
        buffer.frameLength = buffer.frameCapacity
        chunk.samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: chunk.samples.count) }
        if !engine.isRunning, !interrupted { try restartEngine() }
        let count = chunk.samples.count
        queuedSamples += count
        lastProgress = .now
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            Task { await self.playedBack(count, utterance: token) }
        }
        startOrResumeIfReady()
    }

    /// Marks the utterance complete. `onDrained` runs once the last sample has played, or once the player
    /// has gone without playback progress for longer than the remaining audio should take.
    func finish(utterance token: UUID, onDrained: @escaping @Sendable () -> Void) {
        guard token == utterance else {
            onDrained()
            return
        }
        self.onDrained = onDrained
        finished = true
        startOrResumeIfReady()
        if queuedSamples == 0 {
            completeUtterance()
        } else {
            armDrainWatchdog()
        }
    }

    /// Suspends while more than `seconds` of audio is queued, so generation does not run arbitrarily far ahead.
    func waitUntilQueued(below seconds: Double) async throws {
        while let format, Double(queuedSamples) / format.sampleRate > seconds {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func stop() {
        utterance = UUID()
        drainWatchdog?.cancel()
        drainWatchdog = nil
        onDrained = nil
        node.stop()
        engine.stop()
        if format != nil { engine.disconnectNodeOutput(node) }
        format = nil
        queuedSamples = 0
        finished = false
        playbackStarted = false
        rebuffering = false
        interrupted = false
        rebufferTarget = 0
        underruns = 0
        rebufferStartedAt = nil
        if sessionOwned {
            sessionOwned = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: Engine

    private func start(sampleRate: Int) async throws {
        if configuration.managesAudioSession {
            await configureSession()
        }
        guard let created = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1) else {
            throw MarvisError.message("Could not configure audio playback.")
        }
        format = created
        engine.connect(node, to: engine.mainMixerNode, format: created)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.disconnectNodeOutput(node)
            format = nil
            throw MarvisError.message("Audio engine could not start: \(MarvisDiagnostics.describe(error))")
        }
        installObservers()
        let prebuffer = prebufferSeconds()
        rebufferTarget = samples(for: prebuffer)
        let basis = expectedRTF.map { String(format: " for rtf %.2f", $0) } ?? ""
        MarvisDiagnostics.log("player: started, route \(routeDescription), prebuffer \(MarvisDiagnostics.seconds(prebuffer))\(basis)")
    }

    /// Prepares the shared audio session without ever failing the utterance over it. A host that is
    /// recording (speech recognizer) keeps its `.playAndRecord` category; output is sent to the speaker so
    /// speech is not played through the receiver. Activation can be refused with "insufficient priority"
    /// while a recognizer, Siri or a call still holds audio, which is usually over within a moment, so it
    /// is retried once. If the session still cannot be activated the engine is started anyway; only an
    /// engine that cannot start fails the utterance.
    private func configureSession() async {
        let session = AVAudioSession.sharedInstance()
        if session.category == .playAndRecord || session.category == .record {
            MarvisDiagnostics.log("player: host session is \(session.category.rawValue), keeping it")
            if session.category == .playAndRecord, !session.categoryOptions.contains(.defaultToSpeaker) {
                do {
                    try session.overrideOutputAudioPort(.speaker)
                } catch {
                    MarvisDiagnostics.log("player: could not route to the speaker: \(MarvisDiagnostics.describe(error))")
                }
            }
        } else {
            do {
                try session.setCategory(.playback, mode: .spokenAudio, options: [])
                sessionOwned = true
            } catch {
                MarvisDiagnostics.log("player: could not set the playback category: \(MarvisDiagnostics.describe(error))")
            }
        }
        for attempt in 1...2 {
            do {
                try session.setActive(true)
                return
            } catch {
                MarvisDiagnostics.log("player: session activation failed (attempt \(attempt)): \(MarvisDiagnostics.describe(error))")
                if attempt == 1 { try? await Task.sleep(for: .milliseconds(350)) }
            }
        }
        MarvisDiagnostics.log("player: continuing without activating the session")
    }

    /// Restarts a stopped engine. Calling `play` on a node whose engine is stopped raises an exception, so
    /// every path that plays goes through here first.
    private func restartEngine() throws {
        guard format != nil else { return }
        do {
            try engine.start()
        } catch {
            throw MarvisError.message("Audio engine could not be restarted: \(MarvisDiagnostics.describe(error))")
        }
        if playbackStarted, !rebuffering, !interrupted { node.play() }
    }

    private func play() {
        if !engine.isRunning {
            do {
                try restartEngine()
            } catch {
                MarvisDiagnostics.log("player: \(error.localizedDescription)")
                return
            }
        }
        node.play()
    }

    private var routeDescription: String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName)
        return outputs.isEmpty ? "no output" : outputs.joined(separator: "+")
    }

    // MARK: Buffering

    /// Slow generation needs more audio in hand before playback starts; fast generation can start sooner.
    private func prebufferSeconds() -> Double {
        let base = configuration.initialPrebufferSeconds
        guard let rtf = expectedRTF else { return base }
        return min(configuration.maximumRebufferSeconds, max(base, base + 2.0 * (rtf - 0.5)))
    }

    private func samples(for seconds: Double) -> Int {
        Int(seconds * (format?.sampleRate ?? 24_000))
    }

    private var queuedSeconds: Double {
        Double(queuedSamples) / (format?.sampleRate ?? 24_000)
    }

    private func startOrResumeIfReady() {
        guard !interrupted, queuedSamples > 0, finished || queuedSamples >= rebufferTarget else { return }
        if !playbackStarted {
            playbackStarted = true
            play()
        } else if rebuffering {
            rebuffering = false
            if let since = rebufferStartedAt {
                let waited = MarvisDiagnostics.toSeconds(since.duration(to: .now))
                statistics.rebufferTime += waited
                MarvisDiagnostics.log("player: resumed after \(MarvisDiagnostics.seconds(waited)) with \(MarvisDiagnostics.seconds(queuedSeconds)) buffered")
            }
            rebufferStartedAt = nil
            play()
        }
    }

    private func playedBack(_ count: Int, utterance token: UUID) {
        guard token == utterance else { return }
        queuedSamples = max(0, queuedSamples - count)
        lastProgress = .now
        if finished {
            checkDrain()
            return
        }
        guard playbackStarted, !rebuffering, !interrupted,
              queuedSamples <= samples(for: configuration.lowWaterSeconds) else { return }
        // Generation is not keeping up. Pause and rebuild the buffer instead of playing fragments with gaps.
        rebuffering = true
        if engine.isRunning { node.pause() }
        underruns += 1
        statistics.underruns += 1
        rebufferStartedAt = .now
        let base = max(prebufferSeconds(), configuration.rebufferSeconds)
        let target = min(configuration.maximumRebufferSeconds, base * pow(1.5, Double(underruns - 1)))
        rebufferTarget = samples(for: target)
        MarvisDiagnostics.log("player: ran dry (#\(underruns)), pausing until \(MarvisDiagnostics.seconds(target)) is buffered")
        startOrResumeIfReady()
    }

    private func checkDrain() {
        guard finished, queuedSamples == 0 else { return }
        completeUtterance()
    }

    private func completeUtterance() {
        let callback = onDrained
        stop()
        callback?()
    }

    // MARK: Watchdog

    /// Completion callbacks stop arriving if the engine is torn down underneath us. Never let `finish` wait
    /// longer than the remaining audio should take to play, plus a margin.
    private func armDrainWatchdog() {
        drainWatchdog?.cancel()
        let token = utterance
        drainWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let delay = await self.watchdogDelay(utterance: token) else { return }
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
                if await self.endIfStalled(utterance: token) { return }
            }
        }
    }

    private func watchdogDelay(utterance token: UUID) -> Double? {
        guard token == utterance, finished, queuedSamples > 0 else { return nil }
        return queuedSeconds + 2.0
    }

    /// Returns true when the watchdog has nothing left to do.
    private func endIfStalled(utterance token: UUID) -> Bool {
        guard token == utterance, finished, queuedSamples > 0 else { return true }
        let idle = MarvisDiagnostics.toSeconds(lastProgress.duration(to: .now))
        guard idle >= queuedSeconds + 2.0 else { return false }
        statistics.forcedDrains += 1
        MarvisDiagnostics.log("player: no playback progress for \(MarvisDiagnostics.seconds(idle)) with \(MarvisDiagnostics.seconds(queuedSeconds)) queued, ending utterance")
        completeUtterance()
        return true
    }

    // MARK: Engine and session notifications

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            Task { await self.engineConfigurationChanged() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] notification in
            guard let self else { return }
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = AVAudioSession.InterruptionOptions(
                rawValue: notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            Task { await self.sessionInterruption(type: type, options: options) }
        })
    }

    /// Another audio user in the process changed the hardware configuration (sample rate, channels, route).
    /// The engine stops itself when that happens and has to be started again.
    private func engineConfigurationChanged() {
        statistics.configurationChanges += 1
        guard format != nil else { return }
        if engine.isRunning {
            MarvisDiagnostics.log("player: engine configuration changed (route \(routeDescription)), still running")
            return
        }
        do {
            try restartEngine()
            MarvisDiagnostics.log("player: engine configuration changed (route \(routeDescription)), restarted")
        } catch {
            MarvisDiagnostics.log("player: engine configuration changed (route \(routeDescription)), \(error.localizedDescription)")
        }
    }

    private func sessionInterruption(type: AVAudioSession.InterruptionType?, options: AVAudioSession.InterruptionOptions) {
        guard format != nil, let type else { return }
        switch type {
        case .began:
            guard !interrupted else { return }
            interrupted = true
            statistics.interruptions += 1
            if engine.isRunning { node.pause() }
            MarvisDiagnostics.log("player: audio session interrupted, pausing")
        case .ended:
            guard interrupted else { return }
            interrupted = false
            if configuration.managesAudioSession {
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                } catch {
                    MarvisDiagnostics.log("player: reactivation after interruption failed: \(MarvisDiagnostics.describe(error))")
                }
            }
            do {
                try restartEngine()
                MarvisDiagnostics.log("player: interruption ended (shouldResume \(options.contains(.shouldResume))), resuming")
            } catch {
                MarvisDiagnostics.log("player: interruption ended but \(error.localizedDescription)")
            }
            startOrResumeIfReady()
        @unknown default:
            break
        }
    }
}
