import FluidAudio
import Foundation

struct SpeechSegment: Sendable {
    let start: Double
    let end: Double
    let text: String
}

struct SpeechTranscriptionResult: Sendable {
    let text: String
    let segments: [SpeechSegment]
}

actor TranscriptionCoordinator {
    private let fluidTranscriber = FluidAudioTranscriber()
    private let whisperTranscriber = WhisperCppTranscriber()
    private var _nemotronTranscriber: Any?
    private var activeBackend: String?

    @available(macOS 15, *)
    private var nemotronTranscriber: NemotronStreamingTranscriber {
        if _nemotronTranscriber == nil {
            _nemotronTranscriber = NemotronStreamingTranscriber()
        }
        return _nemotronTranscriber as! NemotronStreamingTranscriber
    }

    func preload(backend: BackendOption, progress: ((Double, String?) -> Void)? = nil) async {
        activeBackend = backend.backend
        switch backend.backend {
        case "fluidaudio":
            let version: AsrModelVersion = backend.model.contains("v2") ? .v2 : .v3
            do {
                try await fluidTranscriber.loadModels(version: version, progress: progress)
            } catch {
                fputs("[muesli-native] FluidAudio preload failed: \(error)\n", stderr)
            }
        case "whisper":
            do {
                try await whisperTranscriber.loadModel(modelName: backend.model, progress: progress)
            } catch {
                fputs("[muesli-native] whisper.cpp preload failed: \(error)\n", stderr)
            }
        case "nemotron":
            if #available(macOS 15, *) {
                do {
                    try await nemotronTranscriber.loadModels(progress: progress)
                } catch {
                    fputs("[muesli-native] Nemotron preload failed: \(error)\n", stderr)
                }
            } else {
                fputs("[muesli-native] Nemotron requires macOS 15+\n", stderr)
            }
        default:
            fputs("[muesli-native] unknown backend: \(backend.backend)\n", stderr)
        }
    }

    func transcribeDictation(at url: URL, backend: BackendOption, customWords: [[String: Any]] = []) async throws -> SpeechTranscriptionResult {
        try await route(url: url, backend: backend)
    }

    func transcribeMeeting(at url: URL, backend: BackendOption, customWords: [[String: Any]] = []) async throws -> SpeechTranscriptionResult {
        try await route(url: url, backend: backend)
    }

    func transcribeMeetingChunk(at url: URL, backend: BackendOption, customWords: [[String: Any]] = []) async throws -> SpeechTranscriptionResult {
        try await route(url: url, backend: backend)
    }

    func shutdown() {
        Task {
            await fluidTranscriber.shutdown()
            await whisperTranscriber.shutdown()
            if #available(macOS 15, *) {
                await nemotronTranscriber.shutdown()
            }
        }
    }

    private func route(url: URL, backend: BackendOption) async throws -> SpeechTranscriptionResult {
        switch backend.backend {
        case "whisper":
            return try await transcribeWithWhisperCpp(url: url)
        case "nemotron":
            return try await transcribeWithNemotron(url: url)
        default:
            return try await transcribeWithFluidAudio(url: url)
        }
    }

    // MARK: - FluidAudio (Parakeet on ANE)

    private func transcribeWithFluidAudio(url: URL) async throws -> SpeechTranscriptionResult {
        fputs("[muesli-native] transcribing with FluidAudio: \(url.lastPathComponent)\n", stderr)
        let result = try await fluidTranscriber.transcribe(wavURL: url)
        fputs("[muesli-native] FluidAudio result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = (result.tokenTimings ?? []).map { timing in
            SpeechSegment(start: timing.startTime, end: timing.endTime, text: timing.token)
        }
        return SpeechTranscriptionResult(
            text: text,
            segments: segments.isEmpty && !text.isEmpty ? [SpeechSegment(start: 0, end: result.duration, text: text)] : segments
        )
    }

    // MARK: - whisper.cpp (Whisper on Metal/CPU)

    private func transcribeWithWhisperCpp(url: URL) async throws -> SpeechTranscriptionResult {
        fputs("[muesli-native] transcribing with whisper.cpp: \(url.lastPathComponent)\n", stderr)
        let result = try await whisperTranscriber.transcribe(wavURL: url)
        fputs("[muesli-native] whisper.cpp result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SpeechTranscriptionResult(
            text: text,
            segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
        )
    }

    // MARK: - Nemotron Streaming (RNNT CoreML on ANE)

    private func transcribeWithNemotron(url: URL) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            fputs("[muesli-native] transcribing with Nemotron: \(url.lastPathComponent)\n", stderr)
            let result = try await nemotronTranscriber.transcribe(wavURL: url)
            fputs("[muesli-native] Nemotron result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "Muesli", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Nemotron requires macOS 15 or later.",
            ])
        }
    }

}
