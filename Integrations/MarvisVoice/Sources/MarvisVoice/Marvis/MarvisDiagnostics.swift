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

    /// Audio session errors arrive as bare OSStatus codes; name the ones a host is likely to hit.
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSOSStatusErrorDomain else { return error.localizedDescription }
        let code = nsError.code
        let name: String
        switch code {
        case 561_017_449: name = "insufficient priority: another session (recognizer, Siri, a call) controls audio"
        case 560_030_580: name = "session is busy"
        case 561_015_905: name = "cannot start playing"
        case 560_557_673: name = "cannot interrupt others"
        case 560_161_140: name = "incompatible category"
        case 1_936_290_409: name = "Siri is recording"
        case 561_145_203: name = "resource not available"
        default: name = fourCharacterCode(code) ?? "OSStatus \(code)"
        }
        return "\(name) (\(code))"
    }

    private static func fourCharacterCode(_ code: Int) -> String? {
        guard code > 0, code <= Int(UInt32.max) else { return nil }
        let value = UInt32(code)
        let scalars = (0..<4).map { UInt8((value >> (8 * UInt32(3 - $0))) & 0xFF) }
        guard scalars.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return "'" + String(decoding: scalars, as: UTF8.self) + "'"
    }
}
