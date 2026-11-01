//
//  ContentView.swift
//  MarvisAudioTest
//
//  Created by Ramasamy, Karthick on 01/11/26.
//

import SwiftUI
import WFFargoMarvisVoice

/// Diagnostics lines from the voice package, kept for display.
@MainActor @Observable
final class DiagnosticsLog {
    var lines: [String] = []

    func append(_ line: String) {
        lines.append(line)
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
    }
}

struct ContentView: View {
    private let announcer = FargoMarvisAnnouncer()
    @State private var text: String = ContentView.sampleText
    @State private var status: String = "Idle"
    @State private var isSpeaking: Bool = false
    @State private var log = DiagnosticsLog()
    @State private var exitTask: Task<Void, Never>?

    private static let queuedNotification = FargoMarvisAnnouncer.queuedNotification
    private static let finishedNotification = FargoMarvisAnnouncer.finishedNotification

    var body: some View {
        VStack(spacing: 12) {
            Text("Marvis Audio Test")
                .font(.title2.bold())

            Text(status)
                .font(.footnote)
                .foregroundStyle(isSpeaking ? .green : .secondary)

            TextEditor(text: $text)
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 140)
                .padding(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.secondary.opacity(0.3), lineWidth: 1)
                )

            HStack(spacing: 12) {
                Button {
                    speak()
                } label: {
                    Label("Speak", systemImage: "speaker.wave.2.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSpeaking)

                Button(role: .destructive) {
                    announcer.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!isSpeaking)
            }

            HStack {
                Button("Reset sample text") { text = ContentView.sampleText }
                    .font(.footnote)
                Spacer()
                Button("Clear log") { log.lines.removeAll() }
                    .font(.footnote)
            }

            diagnosticsView
        }
        .padding()
        .onAppear {
            let log = self.log
            announcer.onDiagnostic = { line in
                Task { @MainActor in
                    log.append(line)
                    TestScenarios.log(line)
                }
            }
            // Always record, so a manual session can be pulled off the device and analyzed afterwards.
            announcer.audioTap = { samples, rate in
                TestAudioRecorder.shared.append(samples, sampleRate: rate)
            }
            TestScenarios.log("test: app launched")
            guard announcer.isAvailable else {
                status = "Marvis unavailable (needs a Metal device, not simulator)"
                return
            }
            announcer.prewarm()
            status = "Prewarming Marvis…"
            // Launch arguments let a command-line device run exercise the pipeline without a tap.
            if let scenario = TestScenarios.selected {
                TestScenarios.run(scenario, announcer: announcer, sampleText: Self.sampleText)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.queuedNotification)) { _ in
            isSpeaking = true
            status = "Speaking…"
            TestScenarios.log("notification: fargoSpeechAnnouncementQueued")
            exitTask?.cancel()
            exitTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.finishedNotification)) { _ in
            isSpeaking = false
            status = "Done"
            TestScenarios.log("notification: fargoSpeechAnnouncementFinished")
            if let line = TestAudioRecorder.shared.flush() {
                TestScenarios.log(line)
                log.append(line)
            }
            if TestScenarios.exitsWhenDone {
                exitTask?.cancel()
                exitTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    // A new announcement cancels this task; a cancelled sleep must not fall through to exit.
                    guard !Task.isCancelled else { return }
                    TestScenarios.log("test: done, exiting")
                    exit(0)
                }
            }
        }
    }

    /// Generation speed, quality changes, player underruns and rebuffering, as the package reports them.
    private var diagnosticsView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(log.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(6)
            }
            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 220)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: log.lines.count) { _, count in
                guard count > 0 else { return }
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }

    private func speak() {
        announcer.announce([text])
    }

    private static let sampleText = """
    Hello, this is a longer test utterance for the Marvis neural voice engine. \
    The purpose of this sample app is to isolate and reproduce the audio distortion \
    that appears when WFFargoMarvisVoice is embedded inside the larger Fargo application. \
    By running the same synthesizer and playback pipeline in a minimal container, we can \
    rule out interference from unrelated audio sessions, background services, or other \
    features that may compete for the microphone, the speaker, or the audio session category. \
    Please listen carefully for any clicks, pops, chirps, or sudden changes in pitch while \
    this sentence is being spoken, and note whether the distortion appears at the very start, \
    somewhere in the middle, or near the end of the reply. If the audio sounds completely \
    clean here, then we know the regression is almost certainly caused by something outside \
    of the Marvis package itself. Thanks for listening, and happy debugging.
    """
}

#Preview {
    ContentView()
}
