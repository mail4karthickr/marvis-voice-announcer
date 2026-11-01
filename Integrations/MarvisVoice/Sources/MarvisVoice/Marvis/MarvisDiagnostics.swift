import Foundation
import os

/// Telemetry about synthesis and playback, so a host app can see why speech sounds the way it does.
///
/// Every message goes to the unified log (subsystem `MarvisVoice`, category `Marvis`). A host can
/// also receive the same lines through `MarvisAnnouncer.onDiagnostic` or `Marvis.onDiagnostic`.
enum MarvisDiagnostics {
    private static let logger = Logger(subsystem: "MarvisVoice", category: "Marvis")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sink: (@Sendable (String) -> Void)?
    nonisolated(unsafe) private static var audioSink: (@Sendable ([Float], Int) -> Void)?

    static func setSink(_ newSink: (@Sendable (String) -> Void)?) {
        lock.withLock { sink = newSink }
    }

    static func setAudioSink(_ newSink: (@Sendable ([Float], Int) -> Void)?) {
        lock.withLock { audioSink = newSink }
    }

    /// Hands a PCM chunk to the host's tap, if any, as it is queued for playback.
    static func tap(_ samples: [Float], sampleRate: Int) {
        let sink = lock.withLock { Self.audioSink }
        sink?(samples, sampleRate)
    }

    static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        let sink = lock.withLock { Self.sink }
        sink?(message)
    }

    static func toSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.2fs", value)
    }

    static func megabytes(_ bytes: Int) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}
