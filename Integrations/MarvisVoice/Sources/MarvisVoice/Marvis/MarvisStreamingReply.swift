import Foundation

/// Keep response generation and speech in the same cancellable operation.
@MainActor
enum MarvisStreamingReply {
    static func run(
        style: MarvisStreamingSpeechText.Style = .immediate,
        generate: @escaping @MainActor (@escaping @MainActor (String) -> Void) async throws -> Void,
        speak: @escaping @MainActor (AsyncThrowingStream<String, Error>) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        // The caller bounds the model's response tokens. Retain every phrase;
        // dropping a buffered element would silently omit words from the reply.
        let (phrases, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        defer { continuation.finish() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await generatePhrases(using: generate, style: style, continuation: continuation)
            }

            group.addTask {
                try Task.checkCancellation()
                try await speak(phrases)
                // AsyncThrowingStream may end normally when its waiter is
                // cancelled. Preserve cancellation for the operation's owner.
                try Task.checkCancellation()
            }

            do {
                while try await group.next() != nil { }
            } catch {
                // React to the first failed child immediately: waiting for all
                // children first could leave generation or playback running.
                group.cancelAll()
                continuation.finish(throwing: error)
                throw error
            }
        }
        try Task.checkCancellation()
    }

    private static func generatePhrases(
        using generate: @escaping @MainActor (@escaping @MainActor (String) -> Void) async throws -> Void,
        style: MarvisStreamingSpeechText.Style,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let buffer = PhraseBuffer(style: style, continuation: continuation)
        // A slow or short stream may not reach even the first word-count
        // threshold. Bound startup buffering without fragmenting later speech.
        async let startup: Void = flushStartupWords(from: buffer)
        do {
            try Task.checkCancellation()
            try await generate { snapshot in
                guard !Task.isCancelled else { return }
                buffer.append(snapshot)
            }
            try Task.checkCancellation()
            buffer.finish()
            try await startup
        } catch {
            buffer.finished = true
            continuation.finish(throwing: error)
            throw error
        }
    }

    private static func flushStartupWords(from buffer: PhraseBuffer) async throws {
        while !buffer.hasEmitted && !buffer.finished {
            try await Task.sleep(for: .milliseconds(120))
            try Task.checkCancellation()
            if !buffer.hasEmitted && !buffer.finished { buffer.flushReadyWords() }
        }
    }

    @MainActor private final class PhraseBuffer {
        var finished = false
        private(set) var hasEmitted = false
        private var text: MarvisStreamingSpeechText
        private let continuation: AsyncThrowingStream<String, Error>.Continuation

        init(style: MarvisStreamingSpeechText.Style, continuation: AsyncThrowingStream<String, Error>.Continuation) {
            self.text = MarvisStreamingSpeechText(style: style)
            self.continuation = continuation
        }

        func append(_ snapshot: String) { emit(text.append(snapshot)) }
        func flushReadyWords() { emit(text.flushReadyWords()) }

        func finish() {
            emit(text.finish())
            finished = true
            continuation.finish()
        }

        private func emit(_ phrases: [String]) {
            guard !finished else { return }
            for phrase in phrases {
                hasEmitted = true
                continuation.yield(phrase)
            }
        }
    }
}
