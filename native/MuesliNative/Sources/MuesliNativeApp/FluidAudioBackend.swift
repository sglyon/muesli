import FluidAudio
import Foundation

/// Native Swift transcription backend using FluidAudio's Parakeet TDT model
/// running on Apple's Neural Engine (ANE) via CoreML.
actor FluidAudioTranscriber {
    private var asrManager: AsrManager?
    private var loadedVersion: AsrModelVersion?

    enum TranscriberError: Error, LocalizedError {
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "FluidAudio models not loaded. Call loadModels() first."
            }
        }
    }

    /// Downloads models (if needed) and initializes the ASR manager.
    /// - Parameter version: .v3 for multilingual (25 langs), .v2 for English-only
    func loadModels(version: AsrModelVersion = .v3, progress: ((Double, String?) -> Void)? = nil) async throws {
        if loadedVersion == version, asrManager != nil { return }

        fputs("[fluidaudio] downloading/loading models (version: \(version))...\n", stderr)
        let models = try await AsrModels.downloadAndLoad(version: version) { downloadProgress in
            let fraction = downloadProgress.fractionCompleted
            DispatchQueue.main.async {
                progress?(fraction, "Downloading Parakeet model...")
            }
        }
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        self.asrManager = manager
        self.loadedVersion = version
        fputs("[fluidaudio] models ready\n", stderr)
    }

    /// Transcribe a WAV file URL directly.
    func transcribe(wavURL: URL) async throws -> ASRResult {
        guard let asrManager else { throw TranscriberError.notLoaded }
        return try await asrManager.transcribe(wavURL)
    }

    func shutdown() {
        asrManager = nil
        loadedVersion = nil
    }
}
