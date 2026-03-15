import Accelerate
@preconcurrency import CoreML
import Foundation

/// Native RNNT streaming ASR backend for NVIDIA Nemotron Speech 0.6B.
/// Runs entirely on Apple Neural Engine via CoreML. No FluidAudio dependency.
///
/// Pipeline: audio → preprocessor → mel → encoder (with cache) → decoder + joint → tokens
/// Model: FluidInference/nemotron-speech-streaming-en-0.6b-coreml (560ms chunks)
@available(macOS 15, iOS 18, *)
actor NemotronStreamingTranscriber {
    // CoreML models
    private var preprocessor: MLModel?
    private var encoder: MLModel?
    private var decoder: MLModel?
    private var joint: MLModel?
    private var tokenizer: [Int: String] = [:]
    private var loaded = false

    // Model config (560ms chunk variant)
    private let chunkMelFrames = 56
    private let preEncodeCacheFrames = 9
    private let melBins = 128
    private let encoderDim = 1024
    private let decoderHiddenSize = 640
    private let decoderLayers = 2
    private let blankTokenId = 1024
    private let sampleRate = 16000

    enum TranscriberError: Error, LocalizedError {
        case notLoaded
        case modelLoadFailed(String)
        case downloadFailed(String)
        case preprocessingFailed
        case decodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .notLoaded: return "Nemotron models not loaded."
            case .modelLoadFailed(let m): return "Model load failed: \(m)"
            case .downloadFailed(let m): return "Download failed: \(m)"
            case .preprocessingFailed: return "Audio preprocessing failed."
            case .decodingFailed(let m): return "Decoding failed: \(m)"
            }
        }
    }

    // MARK: - Model Loading

    private static let cacheDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/muesli/models/nemotron-560ms", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func loadModels(progress: ((Double, String?) -> Void)? = nil) async throws {
        if loaded { return }

        let modelDir = try await ensureModelsDownloaded(progress: progress)

        fputs("[nemotron] loading CoreML models...\n", stderr)
        let config = MLModelConfiguration()
        config.computeUnits = .all

        preprocessor = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("preprocessor.mlmodelc"),
            configuration: config
        )
        encoder = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("encoder/encoder_int8.mlmodelc"),
            configuration: config
        )
        decoder = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("decoder.mlmodelc"),
            configuration: config
        )
        joint = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("joint.mlmodelc"),
            configuration: config
        )

        // Load tokenizer
        let tokenizerURL = modelDir.appendingPathComponent("tokenizer.json")
        let tokenizerData = try Data(contentsOf: tokenizerURL)
        if let json = try JSONSerialization.jsonObject(with: tokenizerData) as? [String: Any],
           let vocab = json["model"] as? [String: Any],
           let vocabList = vocab["vocab"] as? [[Any]] {
            for entry in vocabList {
                if let token = entry.first as? String, let id = entry.last as? Int {
                    tokenizer[id] = token
                }
            }
        }

        loaded = true
        fputs("[nemotron] models ready (\(tokenizer.count) vocab tokens)\n", stderr)
    }

    // MARK: - Transcription

    func transcribe(wavURL: URL) async throws -> (text: String, processingTime: Double) {
        guard loaded, let preprocessor, let encoder, let decoder, let joint else {
            throw TranscriberError.notLoaded
        }

        // Load audio as float32 samples
        let samples = try loadWavAsFloats(url: wavURL)
        let start = CFAbsoluteTimeGetCurrent()

        // Process in chunks
        let samplesPerChunk = Int(Double(chunkMelFrames) * 0.01 * Double(sampleRate)) // 56 * 160 = 8960
        let totalMelFrames = chunkMelFrames + preEncodeCacheFrames  // 65

        // Initialize encoder cache
        var cacheChannel = try MLMultiArray(shape: [1, 24, 70, 1024], dataType: .float32)
        var cacheTime = try MLMultiArray(shape: [1, 24, 1024, 8], dataType: .float32)
        var cacheLen = try MLMultiArray(shape: [1], dataType: .float32)
        zeroFill(cacheChannel)
        zeroFill(cacheTime)
        cacheLen[0] = NSNumber(value: 0)

        // Initialize decoder LSTM state
        var decoderState = try initDecoderState()
        var lastToken = 0  // SOS token

        var allTokens: [Int] = []
        var sampleOffset = 0

        while sampleOffset < samples.count {
            let chunkEnd = min(sampleOffset + samplesPerChunk, samples.count)
            let chunkSamples = Array(samples[sampleOffset..<chunkEnd])

            // Pad to full chunk if needed
            let paddedSamples: [Float]
            if chunkSamples.count < samplesPerChunk {
                paddedSamples = chunkSamples + [Float](repeating: 0, count: samplesPerChunk - chunkSamples.count)
            } else {
                paddedSamples = chunkSamples
            }

            // 1. Preprocessor: audio → mel
            let audioArray = try createAudioInput(paddedSamples)
            let melOutput = try await preprocessor.prediction(from: audioArray)
            guard let melArray = melOutput.featureValue(for: "mel_output")?.multiArrayValue else {
                throw TranscriberError.preprocessingFailed
            }

            // 2. Encoder: mel + cache → encoded + new_cache
            let encoderInput = try MLDictionaryFeatureProvider(dictionary: [
                "mel_input": MLFeatureValue(multiArray: melArray),
                "cache_channel": MLFeatureValue(multiArray: cacheChannel),
                "cache_time": MLFeatureValue(multiArray: cacheTime),
                "cache_len": MLFeatureValue(multiArray: cacheLen),
            ])
            let encoderOutput = try await encoder.prediction(from: encoderInput)

            guard let encoded = encoderOutput.featureValue(for: "encoded")?.multiArrayValue else {
                throw TranscriberError.decodingFailed("No encoder output")
            }
            if let newCacheChannel = encoderOutput.featureValue(for: "new_cache_channel")?.multiArrayValue {
                cacheChannel = newCacheChannel
            }
            if let newCacheTime = encoderOutput.featureValue(for: "new_cache_time")?.multiArrayValue {
                cacheTime = newCacheTime
            }
            if let newCacheLen = encoderOutput.featureValue(for: "new_cache_len")?.multiArrayValue {
                cacheLen = newCacheLen
            }

            // 3. RNNT decode: iterate over encoder frames
            let encoderFrames = encoded.shape[2].intValue
            let encoderPtr = encoded.dataPointer.bindMemory(to: Float.self, capacity: encoded.count)

            for t in 0..<encoderFrames {
                // Extract encoder frame [1, 1, encoderDim]
                let encoderFrame = try MLMultiArray(shape: [1, 1, NSNumber(value: encoderDim)], dataType: .float32)
                let framePtr = encoderFrame.dataPointer.bindMemory(to: Float.self, capacity: encoderDim)
                let srcOffset = t * encoderDim
                memcpy(framePtr, encoderPtr.advanced(by: srcOffset), encoderDim * MemoryLayout<Float>.size)

                // Greedy decode loop for this encoder frame
                var maxSteps = 10  // Safety limit per encoder frame
                while maxSteps > 0 {
                    maxSteps -= 1

                    // Decoder: token + LSTM state → decoder_out + new_state
                    let tokenArray = try MLMultiArray(shape: [1, 1], dataType: .int32)
                    tokenArray[0] = NSNumber(value: Int32(lastToken))

                    let decoderInput = try MLDictionaryFeatureProvider(dictionary: [
                        "input_ids": MLFeatureValue(multiArray: tokenArray),
                        "h0": MLFeatureValue(multiArray: decoderState.h0),
                        "c0": MLFeatureValue(multiArray: decoderState.c0),
                        "h1": MLFeatureValue(multiArray: decoderState.h1),
                        "c1": MLFeatureValue(multiArray: decoderState.c1),
                    ])
                    let decoderOutput = try await decoder.prediction(from: decoderInput)

                    guard let decoderOut = decoderOutput.featureValue(for: "decoder_output")?.multiArrayValue else {
                        throw TranscriberError.decodingFailed("No decoder output")
                    }

                    // Joint: encoder_out + decoder_out → logits
                    let jointInput = try MLDictionaryFeatureProvider(dictionary: [
                        "encoder_output": MLFeatureValue(multiArray: encoderFrame),
                        "decoder_output": MLFeatureValue(multiArray: decoderOut),
                    ])
                    let jointOutput = try await joint.prediction(from: jointInput)

                    guard let logits = jointOutput.featureValue(for: "logits")?.multiArrayValue else {
                        throw TranscriberError.decodingFailed("No joint logits")
                    }

                    // Argmax
                    let vocabSize = logits.shape.last!.intValue
                    let logitsPtr = logits.dataPointer.bindMemory(to: Float.self, capacity: vocabSize)
                    var maxVal: Float = -Float.infinity
                    var maxIdx: vDSP_Length = 0
                    vDSP_maxvi(logitsPtr, 1, &maxVal, &maxIdx, vDSP_Length(vocabSize))
                    let predictedToken = Int(maxIdx)

                    if predictedToken == blankTokenId {
                        // BLANK → move to next encoder frame
                        break
                    }

                    // Non-blank → emit token, update decoder state
                    allTokens.append(predictedToken)
                    lastToken = predictedToken

                    // Update LSTM state
                    if let h0 = decoderOutput.featureValue(for: "new_h0")?.multiArrayValue,
                       let c0 = decoderOutput.featureValue(for: "new_c0")?.multiArrayValue,
                       let h1 = decoderOutput.featureValue(for: "new_h1")?.multiArrayValue,
                       let c1 = decoderOutput.featureValue(for: "new_c1")?.multiArrayValue {
                        decoderState = (h0: h0, c0: c0, h1: h1, c1: c1)
                    }
                }
            }

            sampleOffset += samplesPerChunk
        }

        // Decode tokens to text
        let text = decodeTokens(allTokens)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        return (text: text, processingTime: elapsed)
    }

    func shutdown() {
        preprocessor = nil
        encoder = nil
        decoder = nil
        joint = nil
        tokenizer = [:]
        loaded = false
    }

    // MARK: - Token Decoding

    private func decodeTokens(_ tokenIds: [Int]) -> String {
        // SentencePiece-style: tokens starting with ▁ (U+2581) represent word boundaries
        var pieces: [String] = []
        for id in tokenIds {
            if let piece = tokenizer[id] {
                pieces.append(piece)
            }
        }
        return pieces.joined()
            .replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - LSTM State

    private typealias LSTMState = (h0: MLMultiArray, c0: MLMultiArray, h1: MLMultiArray, c1: MLMultiArray)

    private func initDecoderState() throws -> LSTMState {
        let shape: [NSNumber] = [1, 1, NSNumber(value: decoderHiddenSize)]
        let h0 = try MLMultiArray(shape: shape, dataType: .float32)
        let c0 = try MLMultiArray(shape: shape, dataType: .float32)
        let h1 = try MLMultiArray(shape: shape, dataType: .float32)
        let c1 = try MLMultiArray(shape: shape, dataType: .float32)
        zeroFill(h0); zeroFill(c0); zeroFill(h1); zeroFill(c1)
        return (h0: h0, c0: c0, h1: h1, c1: c1)
    }

    // MARK: - Helpers

    private func createAudioInput(_ samples: [Float]) throws -> MLDictionaryFeatureProvider {
        let array = try MLMultiArray(shape: [1, NSNumber(value: samples.count)], dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: samples.count)
        samples.withUnsafeBufferPointer { src in
            memcpy(ptr, src.baseAddress!, samples.count * MemoryLayout<Float>.size)
        }
        return try MLDictionaryFeatureProvider(dictionary: [
            "audio_input": MLFeatureValue(multiArray: array)
        ])
    }

    private func zeroFill(_ array: MLMultiArray) {
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        memset(ptr, 0, array.count * MemoryLayout<Float>.size)
    }

    private func loadWavAsFloats(url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count > 44 else {
            throw TranscriberError.decodingFailed("WAV file too small")
        }
        let pcmData = data.dropFirst(44)
        let sampleCount = pcmData.count / 2
        var floats = [Float](repeating: 0, count: sampleCount)
        pcmData.withUnsafeBytes { raw in
            let int16Buffer = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                floats[i] = Float(int16Buffer[i]) / 32767.0
            }
        }
        return floats
    }

    // MARK: - Model Download

    private static let repoBase = "https://huggingface.co/FluidInference/nemotron-speech-streaming-en-0.6b-coreml/resolve/main/nemotron_coreml_560ms"

    private static let requiredFiles = [
        "preprocessor.mlmodelc",
        "encoder/encoder_int8.mlmodelc",
        "decoder.mlmodelc",
        "joint.mlmodelc",
        "tokenizer.json",
        "metadata.json",
    ]

    private func ensureModelsDownloaded(progress: ((Double, String?) -> Void)? = nil) async throws -> URL {
        let modelDir = Self.cacheDir

        // Check if all required files exist
        let allExist = Self.requiredFiles.allSatisfy { file in
            FileManager.default.fileExists(atPath: modelDir.appendingPathComponent(file).path)
        }

        if allExist {
            fputs("[nemotron] models already cached\n", stderr)
            return modelDir
        }

        fputs("[nemotron] downloading 560ms variant from HuggingFace...\n", stderr)
        progress?(0.0, "Downloading Nemotron model...")

        let hfAPI = "https://huggingface.co/api/models/FluidInference/nemotron-speech-streaming-en-0.6b-coreml/tree/main/nemotron_coreml_560ms"
        var filesDownloaded = 0
        try await downloadDirectory(apiURL: hfAPI, localDir: modelDir, remotePath: "nemotron_coreml_560ms") {
            filesDownloaded += 1
            let fraction = min(Double(filesDownloaded) / 50.0, 0.95) // Estimate ~50 files
            progress?(fraction, "Downloading Nemotron model...")
        }

        fputs("[nemotron] download complete\n", stderr)
        return modelDir
    }

    private func downloadDirectory(apiURL: String, localDir: URL, remotePath: String, onFileDownloaded: (() -> Void)? = nil) async throws {
        guard let url = URL(string: apiURL) else { return }

        let (data, _) = try await URLSession.shared.data(from: url)
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        for entry in entries {
            guard let path = entry["path"] as? String,
                  let type = entry["type"] as? String else { continue }

            // Get the relative path after the variant prefix
            let relativePath = String(path.dropFirst(remotePath.count + 1))

            if type == "directory" {
                // Recurse into subdirectory
                let subAPI = "https://huggingface.co/api/models/FluidInference/nemotron-speech-streaming-en-0.6b-coreml/tree/main/\(path)"
                let subDir = localDir.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
                try await downloadDirectory(apiURL: subAPI, localDir: localDir, remotePath: remotePath, onFileDownloaded: onFileDownloaded)
            } else if type == "file" {
                let fileURL = URL(string: "https://huggingface.co/FluidInference/nemotron-speech-streaming-en-0.6b-coreml/resolve/main/\(path)")!
                let localFile = localDir.appendingPathComponent(relativePath)

                if FileManager.default.fileExists(atPath: localFile.path) { continue }

                let parentDir = localFile.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

                fputs("[nemotron] downloading \(relativePath)...\n", stderr)
                let (tempURL, _) = try await URLSession.shared.download(from: fileURL)
                try FileManager.default.moveItem(at: tempURL, to: localFile)
                onFileDownloaded?()
            }
        }
    }
}
