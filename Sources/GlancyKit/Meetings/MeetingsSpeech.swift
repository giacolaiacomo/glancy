import AVFoundation
import Foundation
import Speech

/// On-device speech to text for a recorded track, never on a server.
/// - macOS 26: SpeechAnalyzer with a SpeechTranscriber module, the long-form recogniser (the one
///   Notes and Voice Memos use). Its language model is a system asset, downloaded once if missing;
///   it needs no Speech Recognition permission.
/// - Before: SFSpeechRecognizer with `requiresOnDeviceRecognition`, fed in pieces of at most 55 s
///   cut in pauses (`SpeechChunks`), silent pieces skipped. Needs Speech Recognition.
struct SystemMeetingTranscriber: MeetingTranscribing {
    var needsSpeechPermission: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26, *), SpeechTranscriber.isAvailable { return false }
        #endif
        return true
    }

    func engine(for locale: Locale) async -> MeetingSpeechEngine {
        #if compiler(>=6.2)
        if #available(macOS 26, *), SpeechTranscriber.isAvailable,
           await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil {
            return .analyzer
        }
        #endif
        if let r = SFSpeechRecognizer(locale: locale), r.supportsOnDeviceRecognition { return .recognizer }
        return .unavailable
    }

    func transcribe(_ url: URL, locale: Locale, engine: MeetingSpeechEngine,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [SpokenWord] {
        switch engine {
        case .analyzer:
            #if compiler(>=6.2)
            if #available(macOS 26, *) { return try await Self.analyze(url, locale: locale, progress: progress) }
            #endif
            throw MeetingSpeechError.unavailable
        case .recognizer:
            return try await Self.recognize(url, locale: locale, progress: progress)
        case .unavailable:
            throw MeetingSpeechError.unavailable
        }
    }

    // MARK: SpeechAnalyzer (macOS 26)

    #if compiler(>=6.2)
    @available(macOS 26, *)
    static func analyze(_ url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpokenWord] {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw MeetingSpeechError.unavailable }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: url)
        let length = max(0.001, Double(file.length) / max(1, file.processingFormat.sampleRate))
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task<[SpokenWord], Error> {
            var out: [SpokenWord] = []
            for try await r in transcriber.results {
                let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                let start = r.range.start.seconds, duration = r.range.duration.seconds
                guard !text.isEmpty, start.isFinite else { continue }
                out.append(SpokenWord(text: text, start: start, duration: duration.isFinite ? duration : 0))
                progress(min(1, (start + (duration.isFinite ? duration : 0)) / length))
            }
            return out
        }
        do {
            try await withTaskCancellationHandler {
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            collect.cancel()
            throw error
        }
        return try await collect.value
    }
    #endif

    // MARK: SFSpeechRecognizer, in pieces

    static func recognize(_ url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpokenWord] {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw MeetingSpeechError.unavailable
        }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let perFrame = AVAudioFramePosition((format.sampleRate * SpeechChunks.frame).rounded())
        guard perFrame > 0 else { return [] }
        let energy = try Self.energy(file, perFrame: perFrame)
        let plan = SpeechChunks.plan(energy: energy)
        var out: [SpokenWord] = []
        for chunk in plan {
            try Task.checkCancellation()
            defer { progress(Double(chunk.frames.upperBound) / Double(max(1, energy.count))) }
            guard !chunk.silent else { continue }
            let from = AVAudioFramePosition(chunk.frames.lowerBound) * perFrame
            let count = min(file.length - from, AVAudioFramePosition(chunk.frames.count) * perFrame)
            guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { continue }
            file.framePosition = from
            try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
            let words = try await Self.recognize(buffer, with: recognizer)
            out += words.map { SpokenWord(text: $0.text, start: $0.start + chunk.start, duration: $0.duration) }
        }
        return out
    }

    /// RMS per 100 ms of the whole track (one pass, 64k frames at a time).
    static func energy(_ file: AVAudioFile, perFrame: AVAudioFramePosition) throws -> [Float] {
        let format = file.processingFormat
        let block: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block) else { return [] }
        var out: [Float] = []
        var sum: Double = 0, n: AVAudioFramePosition = 0
        file.framePosition = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: block)
            let len = Int(buffer.frameLength)
            guard len > 0, let data = buffer.floatChannelData?[0] else { break }
            for i in 0..<len {
                let v = Double(data[i])
                sum += v * v
                n += 1
                if n == perFrame {
                    out.append(Float((sum / Double(n)).squareRoot()))
                    sum = 0; n = 0
                }
            }
        }
        if n > 0 { out.append(Float((sum / Double(n)).squareRoot())) }
        return out
    }

    private static func recognize(_ buffer: AVAudioPCMBuffer, with recognizer: SFSpeechRecognizer) async throws -> [SpokenWord] {
        let request = SFSpeechAudioBufferRecognitionRequest()
        // Never send audio to a server: no on-device model, no transcript.
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.append(buffer)
        request.endAudio()
        let once = Once()
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[SpokenWord], Error>) in
                box.task = recognizer.recognitionTask(with: request) { @Sendable result, error in
                    if let result, result.isFinal {
                        let words = result.bestTranscription.segments.map {
                            SpokenWord(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                        }
                        if once.claim() { cont.resume(returning: words) }
                    } else if let error {
                        // "No speech detected": nothing said in this piece, not a failure.
                        let code = (error as NSError).code
                        if once.claim() {
                            if code == 1110 || code == 203 { cont.resume(returning: []) } else { cont.resume(throwing: error) }
                        }
                    }
                }
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }

    private final class TaskBox: @unchecked Sendable {
        var task: SFSpeechRecognitionTask?
    }
}

enum MeetingSpeechError: Error { case unavailable }
