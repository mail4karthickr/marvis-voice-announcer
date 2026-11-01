//
//  TestScenarios.swift
//  MarvisAudioTest
//
//  Scripted scenarios for command-line device runs, selected with launch arguments:
//    -scenario basic|stop|interrupt|rapid|streaming|stress   -exitWhenDone
//  Nothing here is part of the MarvisVoice package.
//

import Foundation
import MarvisVoice

@MainActor
enum TestScenarios {
    static let launchTime = Date()

    static var stamp: String {
        String(format: "%7.2f", Date().timeIntervalSince(launchTime))
    }

    static func log(_ line: String) {
        print("[\(stamp)] \(line)")
        TestDiagnosticsFile.shared.append(line)
    }

    static var selected: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-scenario"), index + 1 < arguments.count else {
            return arguments.contains("-autoSpeak") ? "basic" : nil
        }
        return arguments[index + 1]
    }

    static var exitsWhenDone: Bool {
        CommandLine.arguments.contains("-exitWhenDone")
    }

    static func run(_ name: String, announcer: MarvisAnnouncer, sampleText: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            log("test: scenario \(name)")
            switch name {
            case "stop":
                announcer.announce([sampleText])
                try? await Task.sleep(for: .seconds(8))
                log("test: stop()")
                announcer.stop()
                try? await Task.sleep(for: .seconds(2))
                log("test: second announce after stop")
                announcer.announce(["This is the second announcement after a stop. The model should not have reloaded."])

            case "interrupt":
                announcer.announce([sampleText])
                try? await Task.sleep(for: .seconds(8))
                log("test: replacing announcement mid-speech")
                announcer.announce(["Interrupting. This replacement should play completely, and the finished notification should arrive exactly once."])

            case "rapid":
                announcer.announce(["First of three rapid announcements."])
                try? await Task.sleep(for: .milliseconds(150))
                announcer.announce(["Second of three rapid announcements."])
                try? await Task.sleep(for: .milliseconds(150))
                announcer.announce(["Third of three rapid announcements. Only this one should be heard in full."])

            case "streaming":
                announcer.announce(streaming: cumulativeSnapshots(of: sampleText))

            case let repeated where repeated.hasPrefix("repeat"):
                // Consecutive Speak presses, each after the previous reply finished: `repeat5` runs five.
                let rounds = max(1, Int(repeated.dropFirst("repeat".count)) ?? 4)
                for round in 1...rounds {
                    log("test: round \(round)")
                    announcer.announce([sampleText])
                    await waitForFinished()
                    try? await Task.sleep(for: .seconds(1.5))
                }

            case "stress":
                let cores = ProcessInfo.processInfo.activeProcessorCount
                TestLoad.startCPU(threads: cores, qualityOfService: .userInitiated)
                TestLoad.startMemory(megabytes: 1024)
                log("test: load started (\(cores) cpu threads at userInitiated, 1 GB touched)")
                announcer.announce([sampleText])

            case "stress-heavy":
                // Enough high-priority CPU contention to starve MLX's dispatch thread and push the
                // real-time factor past 1, so the pause-and-rebuffer and quality paths actually run.
                let cores = ProcessInfo.processInfo.activeProcessorCount
                TestLoad.startCPU(threads: cores * 4, qualityOfService: .userInteractive)
                TestLoad.startMemory(megabytes: 1536)
                log("test: heavy load started (\(cores * 4) cpu threads at userInteractive, 1.5 GB touched)")
                announcer.announce([sampleText])

            default:
                announcer.announce([sampleText])
            }
        }
    }

    private static func waitForFinished() async {
        let name = MarvisAnnouncer.finishedNotification
        for await _ in NotificationCenter.default.notifications(named: name) { return }
    }

    /// Simulates a language model: cumulative snapshots growing by a word every 120 ms.
    private static func cumulativeSnapshots(of text: String) -> AsyncThrowingStream<String, Error> {
        let words = text.split(separator: " ").map(String.init)
        return AsyncThrowingStream { continuation in
            Task {
                var reply = ""
                for word in words {
                    reply += reply.isEmpty ? word : " " + word
                    continuation.yield(reply)
                    try? await Task.sleep(for: .milliseconds(120))
                }
                continuation.finish()
            }
        }
    }
}

/// Synthetic host load, standing in for a busy app around the voice package.
enum TestLoad {
    nonisolated(unsafe) static var sink = 0.0
    nonisolated(unsafe) static var block: UnsafeMutableRawPointer?
    nonisolated(unsafe) static var blockSize = 0

    static func startCPU(threads: Int, qualityOfService: QualityOfService) {
        for _ in 0..<threads {
            let thread = Thread {
                var x = 0.5
                while true {
                    x = sin(x) * 1.0001 + 0.1
                    sink = x
                }
            }
            thread.qualityOfService = qualityOfService
            thread.start()
        }
    }

    static func startMemory(megabytes: Int) {
        let size = megabytes * 1_048_576
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16_384)
        memset(pointer, 1, size)
        block = pointer
        blockSize = size
        let thread = Thread {
            var value: UInt8 = 0
            while let block {
                var offset = 0
                while offset < blockSize {
                    block.storeBytes(of: value, toByteOffset: offset, as: UInt8.self)
                    offset += 16_384
                }
                value &+= 1
            }
        }
        thread.qualityOfService = .utility
        thread.start()
    }
}


/// Appends every diagnostics line to Documents/diagnostics.log, so a manual session can be pulled off the
/// device afterwards with `devicectl device copy from`.
nonisolated final class TestDiagnosticsFile: @unchecked Sendable {
    static let shared = TestDiagnosticsFile()
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()
    private let url = URL.documentsDirectory.appendingPathComponent("diagnostics.log")
    private var handle: FileHandle?

    private init() {
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func append(_ line: String) {
        lock.withLock {
            let text = "\(formatter.string(from: Date())) \(line)\n"
            if let data = text.data(using: .utf8) {
                try? handle?.write(contentsOf: data)
            }
        }
    }
}

/// Collects the PCM the package queues for playback and writes one WAV per utterance to Documents.
nonisolated final class TestAudioRecorder: @unchecked Sendable {
    static let shared = TestAudioRecorder()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate = 24_000
    private var index = 0

    func append(_ chunk: [Float], sampleRate rate: Int) {
        lock.withLock {
            sampleRate = rate
            samples.append(contentsOf: chunk)
        }
    }

    /// Writes the utterance collected so far and returns a one-line description.
    func flush() -> String? {
        let (data, rate, count): ([Float], Int, Int) = lock.withLock {
            defer { samples.removeAll(keepingCapacity: true) }
            index += 1
            return (samples, sampleRate, index)
        }
        guard !data.isEmpty else { return nil }
        let stamp = Self.fileStamp.string(from: Date())
        let name = "utterance-\(stamp)-\(count).wav"
        let url = URL.documentsDirectory.appendingPathComponent(name)
        pruneRecordings(keeping: 12)
        var bytes = Data()
        func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        let payload = UInt32(data.count * 2)
        bytes.append(contentsOf: Array("RIFF".utf8)); put32(36 + payload)
        bytes.append(contentsOf: Array("WAVE".utf8))
        bytes.append(contentsOf: Array("fmt ".utf8)); put32(16); put16(1); put16(1)
        put32(UInt32(rate)); put32(UInt32(rate * 2)); put16(2); put16(16)
        bytes.append(contentsOf: Array("data".utf8)); put32(payload)
        var pcm = [Int16](repeating: 0, count: data.count)
        var peak: Float = 0
        var overshoot = 0
        var energy: Double = 0
        for (i, sample) in data.enumerated() {
            let clipped = max(-1, min(1, sample))
            pcm[i] = Int16(clipped * 32767)
            peak = max(peak, abs(sample))
            if abs(sample) > 1 { overshoot += 1 }
            energy += Double(clipped * clipped)
        }
        pcm.withUnsafeBufferPointer { bytes.append(contentsOf: UnsafeRawBufferPointer($0)) }
        do {
            try bytes.write(to: url)
        } catch {
            return "audio: failed to write \(name): \(error.localizedDescription)"
        }
        let seconds = Double(data.count) / Double(rate)
        let rms = (energy / Double(data.count)).squareRoot()
        return String(format: "audio: wrote %@ %.2fs rms %.3f true peak %.2f, %d samples above full scale",
                      name, seconds, rms, peak, overshoot)
    }

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// Keeps Documents from filling up across many manual sessions.
    private func pruneRecordings(keeping limit: Int) {
        let directory = URL.documentsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let recordings = files.filter { $0.lastPathComponent.hasPrefix("utterance-") && $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard recordings.count >= limit else { return }
        for url in recordings.prefix(recordings.count - limit + 1) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
