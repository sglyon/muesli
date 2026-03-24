import Accelerate
@preconcurrency import CoreML
import FluidAudio
import Foundation

private enum CanaryQwenConfig {
    static let repoId = "phequals/canary-qwen-2.5b-coreml-int8"
    static let envOverride = "MUESLI_CANARY_MODEL_DIR"

    static let encoderPackage = "encoder_int8.mlpackage"
    static let projectionPackage = "projection.mlpackage"
    static let decoderPackage = "canary_decoder_stateful_int8.mlpackage"
    static let lmHeadPackage = "canary_lm_head_int8.mlpackage"
    static let embeddingsFile = "canary_embeddings.bin"
    static let vocabFile = "vocab.json"
    static let melFilterFile = "canary_mel_filter_bank.bin"
    static let melWindowFile = "canary_mel_window.bin"

    static let maxCacheLen = 256
    static let hiddenSize = 2048
    static let headDim = 128
    static let ropeTheta: Float = 1_000_000
    static let encoderFrames = 500
    static let chunkOverlapFrames = 80
    static let maxNewTokens = 50

    static let promptText =
        "Transcribe the spoken audio accurately. If a word is unclear, use the most likely word that fits well within the context of the overall sentence transcription."
    static let beforePromptIds: [Int32] = [
        151644, 872, 198, 3167, 3114, 279, 21355, 7699, 29257, 13, 1416, 264, 3409, 374,
        24416, 11, 990, 279, 1429, 4363, 3409, 429, 18304, 1632, 2878, 279, 2266, 315,
        279, 8084, 11652, 45840, 13,
    ]
    static let afterPromptIds: [Int32] = [151645, 198, 151644, 77091, 198]
    static let stopTokenIds: Set<Int> = [151645]

    static let requiredRelativeFiles: [String] = [
        "\(encoderPackage)/Manifest.json",
        "\(encoderPackage)/Data/com.apple.CoreML/model.mlmodel",
        "\(encoderPackage)/Data/com.apple.CoreML/weights/weight.bin",
        "\(projectionPackage)/Manifest.json",
        "\(projectionPackage)/Data/com.apple.CoreML/model.mlmodel",
        "\(projectionPackage)/Data/com.apple.CoreML/weights/weight.bin",
        "\(decoderPackage)/Manifest.json",
        "\(decoderPackage)/Data/com.apple.CoreML/model.mlmodel",
        "\(decoderPackage)/Data/com.apple.CoreML/weights/weight.bin",
        "\(lmHeadPackage)/Manifest.json",
        "\(lmHeadPackage)/Data/com.apple.CoreML/model.mlmodel",
        "\(lmHeadPackage)/Data/com.apple.CoreML/weights/weight.bin",
        embeddingsFile,
        vocabFile,
        melFilterFile,
        melWindowFile,
    ]

    static var defaultCacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/muesli/models", isDirectory: true)
            .appendingPathComponent("canary-qwen-2.5b-coreml-int8", isDirectory: true)
    }
}

private struct CanaryChunkSpan {
    let index: Int
    let startFrame: Int
    let endFrame: Int
    let durationS: Double
}

private struct CanaryTimingBreakdown {
    var encoderMs: Double = 0
    var projectionMs: Double = 0
    var decoderPrefillMs: Double = 0
    var lmHeadPrefillMs: Double = 0
    var decoderDecodeMs: Double = 0
    var lmHeadDecodeMs: Double = 0

    var totalMs: Double {
        encoderMs + projectionMs + decoderPrefillMs + lmHeadPrefillMs + decoderDecodeMs + lmHeadDecodeMs
    }
}

private final class CanaryEmbeddingWeights: @unchecked Sendable {
    let vocabSize: Int
    let hiddenSize: Int
    private let data: Data

    init(contentsOf url: URL) throws {
        let fileData = try Data(contentsOf: url)
        guard fileData.count >= 8 else {
            throw NSError(domain: "CanaryQwen", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Invalid embedding file at \(url.path)",
            ])
        }
        let vocab = fileData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        let hidden = fileData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        self.vocabSize = Int(vocab)
        self.hiddenSize = Int(hidden)
        guard hiddenSize == CanaryQwenConfig.hiddenSize else {
            throw NSError(domain: "CanaryQwen", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "Unexpected embedding hidden size \(hiddenSize)",
            ])
        }
        self.data = fileData
    }

    func embedding(for tokenId: Int) -> [Float] {
        guard tokenId >= 0, tokenId < vocabSize else {
            return [Float](repeating: 0, count: hiddenSize)
        }
        let offset = 8 + tokenId * hiddenSize * 2
        var result = [Float](repeating: 0, count: hiddenSize)
        data.withUnsafeBytes { raw in
            let ptr = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: Float16.self)
            for i in 0..<hiddenSize {
                result[i] = Float(ptr[i])
            }
        }
        return result
    }

    func flatEmbeddings(for tokenIds: [Int32]) -> [Float] {
        var result = [Float]()
        result.reserveCapacity(tokenIds.count * hiddenSize)
        for tokenId in tokenIds {
            result.append(contentsOf: embedding(for: Int(tokenId)))
        }
        return result
    }
}

private struct CanaryQwenRoPE: Sendable {
    private let invFreq: [Float]
    private let headDim: Int = CanaryQwenConfig.headDim
    private let maxPosition: Int = CanaryQwenConfig.maxCacheLen
    private let cosTable: [Float]
    private let sinTable: [Float]

    init() {
        let theta = CanaryQwenConfig.ropeTheta
        let dim = Float(headDim)
        var freq = [Float](repeating: 0, count: headDim / 2)
        for i in stride(from: 0, to: headDim, by: 2) {
            let exponent = Float(i) / dim
            freq[i / 2] = 1.0 / powf(theta, exponent)
        }
        self.invFreq = freq

        var cosVals = [Float](repeating: 0, count: maxPosition * headDim)
        var sinVals = [Float](repeating: 0, count: maxPosition * headDim)
        let halfDim = headDim / 2
        for p in 0..<maxPosition {
            let pos = Float(p)
            let offset = p * headDim
            for i in 0..<halfDim {
                let angle = pos * freq[i]
                let c = cosf(angle)
                let s = sinf(angle)
                cosVals[offset + i] = c
                cosVals[offset + i + halfDim] = c
                sinVals[offset + i] = s
                sinVals[offset + i + halfDim] = s
            }
        }
        self.cosTable = cosVals
        self.sinTable = sinVals
    }

    func computeRange(startPosition: Int, count: Int) -> (cos: [Float], sin: [Float]) {
        let endPosition = startPosition + count
        if endPosition <= maxPosition {
            let start = startPosition * headDim
            let end = endPosition * headDim
            return (Array(cosTable[start..<end]), Array(sinTable[start..<end]))
        }
        return computeDynamicRange(startPosition: startPosition, count: count)
    }

    func fill(position: Int, cosPtr: UnsafeMutablePointer<Float>, sinPtr: UnsafeMutablePointer<Float>) {
        if position < maxPosition {
            let offset = position * headDim
            cosTable.withUnsafeBufferPointer { src in
                _ = memcpy(cosPtr, src.baseAddress!.advanced(by: offset), headDim * MemoryLayout<Float>.stride)
            }
            sinTable.withUnsafeBufferPointer { src in
                _ = memcpy(sinPtr, src.baseAddress!.advanced(by: offset), headDim * MemoryLayout<Float>.stride)
            }
            return
        }
        let dynamic = computeDynamic(position: position)
        dynamic.cos.withUnsafeBufferPointer { src in
            _ = memcpy(cosPtr, src.baseAddress!, headDim * MemoryLayout<Float>.stride)
        }
        dynamic.sin.withUnsafeBufferPointer { src in
            _ = memcpy(sinPtr, src.baseAddress!, headDim * MemoryLayout<Float>.stride)
        }
    }

    private func computeDynamic(position: Int) -> (cos: [Float], sin: [Float]) {
        let halfDim = headDim / 2
        let pos = Float(position)
        var cosVals = [Float](repeating: 0, count: headDim)
        var sinVals = [Float](repeating: 0, count: headDim)
        for i in 0..<halfDim {
            let angle = pos * invFreq[i]
            let c = cosf(angle)
            let s = sinf(angle)
            cosVals[i] = c
            cosVals[i + halfDim] = c
            sinVals[i] = s
            sinVals[i + halfDim] = s
        }
        return (cosVals, sinVals)
    }

    private func computeDynamicRange(startPosition: Int, count: Int) -> (cos: [Float], sin: [Float]) {
        var cosVals = [Float](repeating: 0, count: count * headDim)
        var sinVals = [Float](repeating: 0, count: count * headDim)
        for index in 0..<count {
            let dynamic = computeDynamic(position: startPosition + index)
            let offset = index * headDim
            cosVals.replaceSubrange(offset..<(offset + headDim), with: dynamic.cos)
            sinVals.replaceSubrange(offset..<(offset + headDim), with: dynamic.sin)
        }
        return (cosVals, sinVals)
    }
}

private struct CanaryQwenModels {
    let encoder: MLModel
    let projection: MLModel
    let decoder: MLModel
    let lmHead: MLModel
    let embeddings: CanaryEmbeddingWeights
    let vocabulary: [Int: String]
    let melExtractor: CanaryMelSpectrogram

    static func load(from directory: URL, computeUnits: MLComputeUnits = .all) async throws -> CanaryQwenModels {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        let encoder = try await loadModel(packageName: CanaryQwenConfig.encoderPackage, from: directory, configuration: config)
        let projection = try await loadModel(packageName: CanaryQwenConfig.projectionPackage, from: directory, configuration: config)
        let decoder = try await loadModel(packageName: CanaryQwenConfig.decoderPackage, from: directory, configuration: config)
        let lmHead = try await loadModel(packageName: CanaryQwenConfig.lmHeadPackage, from: directory, configuration: config)

        let embeddings = try CanaryEmbeddingWeights(contentsOf: directory.appendingPathComponent(CanaryQwenConfig.embeddingsFile))
        let vocabulary = try loadVocabulary(from: directory.appendingPathComponent(CanaryQwenConfig.vocabFile))
        let melExtractor = try CanaryMelSpectrogram(
            filterBankURL: directory.appendingPathComponent(CanaryQwenConfig.melFilterFile),
            windowURL: directory.appendingPathComponent(CanaryQwenConfig.melWindowFile)
        )

        return CanaryQwenModels(
            encoder: encoder,
            projection: projection,
            decoder: decoder,
            lmHead: lmHead,
            embeddings: embeddings,
            vocabulary: vocabulary,
            melExtractor: melExtractor
        )
    }

    private static func loadModel(packageName: String, from directory: URL, configuration: MLModelConfiguration) async throws -> MLModel {
        let packageURL = directory.appendingPathComponent(packageName, isDirectory: true)
        let compiledURL = directory.appendingPathComponent(packageName.replacingOccurrences(of: ".mlpackage", with: ".mlmodelc"), isDirectory: true)

        let modelURL: URL
        if FileManager.default.fileExists(atPath: compiledURL.path) {
            modelURL = compiledURL
        } else {
            let compiledTemp = try await MLModel.compileModel(at: packageURL)
            try? FileManager.default.removeItem(at: compiledURL)
            try FileManager.default.copyItem(at: compiledTemp, to: compiledURL)
            try? FileManager.default.removeItem(at: compiledTemp)
            modelURL = compiledURL
        }

        return try await MLModel.load(contentsOf: modelURL, configuration: configuration)
    }

    private static func loadVocabulary(from url: URL) throws -> [Int: String] {
        let data = try Data(contentsOf: url)
        guard let tokenToId = try JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            throw NSError(domain: "CanaryQwen", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "Invalid vocab file at \(url.path)",
            ])
        }
        var idToToken: [Int: String] = [:]
        idToToken.reserveCapacity(tokenToId.count)
        for (token, id) in tokenToId {
            idToToken[id] = token
        }
        return idToToken
    }
}

enum CanaryQwenModelStore {
    static func isAvailableLocally() -> Bool {
        if let overrideDir = localOverrideDirectory(), modelsExist(at: overrideDir) {
            return true
        }
        return modelsExist(at: cacheDirectory())
    }

    static func resolvedDirectory(progress: ((Double, String?) -> Void)? = nil) async throws -> URL {
        if let overrideDir = localOverrideDirectory(), modelsExist(at: overrideDir) {
            progress?(1.0, "Using local Canary model override")
            return overrideDir
        }

        let target = CanaryQwenConfig.defaultCacheDirectory
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        if modelsExist(at: target) {
            progress?(1.0, "Canary Qwen already downloaded")
            return target
        }
        try await downloadMissingFiles(to: target, progress: progress)
        return target
    }

    static func modelsExist(at directory: URL) -> Bool {
        let fm = FileManager.default
        return CanaryQwenConfig.requiredRelativeFiles.allSatisfy { relativePath in
            fm.fileExists(atPath: directory.appendingPathComponent(relativePath).path)
        }
    }

    static func localOverrideDirectory() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment[CanaryQwenConfig.envOverride], !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    static func cacheDirectory() -> URL {
        CanaryQwenConfig.defaultCacheDirectory
    }

    private static func remoteURL(for relativePath: String) -> URL {
        var url = URL(string: "https://huggingface.co/\(CanaryQwenConfig.repoId)/resolve/main")!
        for component in relativePath.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: false)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "download", value: "1")]
        return components.url!
    }

    private static func downloadMissingFiles(to directory: URL, progress: ((Double, String?) -> Void)?) async throws {
        let fm = FileManager.default
        let required = CanaryQwenConfig.requiredRelativeFiles
        let missing = required.filter { !fm.fileExists(atPath: directory.appendingPathComponent($0).path) }
        let total = max(missing.count, 1)
        for (index, relativePath) in missing.enumerated() {
            progress?(Double(index) / Double(total), "Downloading Canary Qwen...")
            let destination = directory.appendingPathComponent(relativePath)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let sourceURL = remoteURL(for: relativePath)
            let (tempURL, response) = try await URLSession.shared.download(from: sourceURL)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw NSError(domain: "CanaryQwen", code: 13, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to download \(relativePath)",
                ])
            }
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: tempURL, to: destination)
        }
        progress?(1.0, "Canary Qwen download complete")
    }
}

@available(macOS 15, *)
private final class CanaryQwenManager {
    private let models: CanaryQwenModels
    private let rope = CanaryQwenRoPE()
    private let beforePromptEmbeds: [Float]
    private let afterPromptEmbeds: [Float]
    private let prefillCausalMask: MLMultiArray
    private let decodeMasks: [Int: MLMultiArray]

    init(models: CanaryQwenModels) throws {
        self.models = models
        self.beforePromptEmbeds = models.embeddings.flatEmbeddings(for: CanaryQwenConfig.beforePromptIds)
        self.afterPromptEmbeds = models.embeddings.flatEmbeddings(for: CanaryQwenConfig.afterPromptIds)
        self.prefillCausalMask = try Self.createPrefillMask(seqLen: CanaryQwenConfig.maxCacheLen)
        var masks: [Int: MLMultiArray] = [:]
        for endStep in 1...CanaryQwenConfig.maxCacheLen {
            masks[endStep] = try Self.createDecodeMask(endStep: endStep)
        }
        self.decodeMasks = masks
    }

    func transcribe(audioSamples: [Float]) async throws -> String {
        let start = CFAbsoluteTimeGetCurrent()
        let mel = models.melExtractor.compute(audio: audioSamples)
        let chunks = scheduleChunks(mel: mel)
        var transcripts: [String] = []
        var aggregate = CanaryTimingBreakdown()

        for chunk in chunks {
            let result = try transcribeChunk(span: chunk.0, melChunk: chunk.1)
            if !result.transcript.isEmpty {
                transcripts.append(result.transcript)
            }
            aggregate.encoderMs += result.timing.encoderMs
            aggregate.projectionMs += result.timing.projectionMs
            aggregate.decoderPrefillMs += result.timing.decoderPrefillMs
            aggregate.lmHeadPrefillMs += result.timing.lmHeadPrefillMs
            aggregate.decoderDecodeMs += result.timing.decoderDecodeMs
            aggregate.lmHeadDecodeMs += result.timing.lmHeadDecodeMs
        }

        let merged = mergeChunkTranscripts(transcripts)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let duration = Double(audioSamples.count) / 16_000.0
        let speed = duration > 0 ? (duration / elapsed) : 0
        fputs(
            "[canary-qwen] total=\(String(format: "%.3f", elapsed))s speed=\(String(format: "%.2f", speed))x encoder=\(String(format: "%.0f", aggregate.encoderMs))ms projection=\(String(format: "%.0f", aggregate.projectionMs))ms prefill=\(String(format: "%.0f", aggregate.decoderPrefillMs + aggregate.lmHeadPrefillMs))ms decode=\(String(format: "%.0f", aggregate.decoderDecodeMs + aggregate.lmHeadDecodeMs))ms\n",
            stderr
        )
        return merged
    }

    private func transcribeChunk(span: CanaryChunkSpan, melChunk: [[Float]]) throws -> (transcript: String, timing: CanaryTimingBreakdown) {
        var timing = CanaryTimingBreakdown()
        let melInput = try createEncoderInput(melChunk)

        let encoderStart = CFAbsoluteTimeGetCurrent()
        let encoderInput = try MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": MLFeatureValue(multiArray: melInput)
        ])
        let encoderOutput = try models.encoder.prediction(from: encoderInput)
        guard let encOut = encoderOutput.featureValue(for: "encoder_output")?.multiArrayValue else {
            throw NSError(domain: "CanaryQwen", code: 14, userInfo: [
                NSLocalizedDescriptionKey: "Missing encoder_output from Canary encoder",
            ])
        }
        timing.encoderMs = (CFAbsoluteTimeGetCurrent() - encoderStart) * 1000

        let projectionStart = CFAbsoluteTimeGetCurrent()
        let projectionInput = try MLDictionaryFeatureProvider(dictionary: [
            "encoder_output": MLFeatureValue(multiArray: encOut)
        ])
        let projectionOutput = try models.projection.prediction(from: projectionInput)
        guard let projected = projectionOutput.featureValue(for: "projected_output")?.multiArrayValue else {
            throw NSError(domain: "CanaryQwen", code: 15, userInfo: [
                NSLocalizedDescriptionKey: "Missing projected_output from Canary projection",
            ])
        }
        timing.projectionMs = (CFAbsoluteTimeGetCurrent() - projectionStart) * 1000

        let audioFrames = projected.shape[1].intValue
        let maxNewTokens = tokenBudget(for: span.durationS)
        let (text, genTiming) = try generate(projectedAudioEmbeds: projected, audioFrames: audioFrames, maxNewTokens: maxNewTokens)
        timing.decoderPrefillMs = genTiming.decoderPrefillMs
        timing.lmHeadPrefillMs = genTiming.lmHeadPrefillMs
        timing.decoderDecodeMs = genTiming.decoderDecodeMs
        timing.lmHeadDecodeMs = genTiming.lmHeadDecodeMs
        return (text, timing)
    }

    private func generate(projectedAudioEmbeds: MLMultiArray, audioFrames: Int, maxNewTokens: Int) throws -> (String, CanaryTimingBreakdown) {
        var timing = CanaryTimingBreakdown()

        let beforeCount = CanaryQwenConfig.beforePromptIds.count
        let afterCount = CanaryQwenConfig.afterPromptIds.count
        let totalSeq = beforeCount + audioFrames + afterCount
        let hiddenSize = CanaryQwenConfig.hiddenSize

        let hiddenArray = try MLMultiArray(shape: [1, NSNumber(value: totalSeq), NSNumber(value: hiddenSize)], dataType: .float32)
        let hiddenPtr = hiddenArray.dataPointer.bindMemory(to: Float.self, capacity: totalSeq * hiddenSize)

        beforePromptEmbeds.withUnsafeBufferPointer { src in
            _ = memcpy(hiddenPtr, src.baseAddress!, beforePromptEmbeds.count * MemoryLayout<Float>.stride)
        }
        copyProjectedAudioEmbeds(projectedAudioEmbeds, to: hiddenPtr.advanced(by: beforePromptEmbeds.count))
        afterPromptEmbeds.withUnsafeBufferPointer { src in
            _ = memcpy(
                hiddenPtr.advanced(by: beforePromptEmbeds.count + (audioFrames * hiddenSize)),
                src.baseAddress!,
                afterPromptEmbeds.count * MemoryLayout<Float>.stride
            )
        }

        let (prefillCosVals, prefillSinVals) = rope.computeRange(startPosition: 0, count: totalSeq)
        let prefillCos = try createPositionArray(values: prefillCosVals, seqLen: totalSeq)
        let prefillSin = try createPositionArray(values: prefillSinVals, seqLen: totalSeq)
        let prefillMask = try slicePrefillMask(seqLen: totalSeq)

        let state = models.decoder.makeState()
        let decoderInput = try MLDictionaryFeatureProvider(dictionary: [
            "hidden_states": MLFeatureValue(multiArray: hiddenArray),
            "position_cos": MLFeatureValue(multiArray: prefillCos),
            "position_sin": MLFeatureValue(multiArray: prefillSin),
            "attention_mask": MLFeatureValue(multiArray: prefillMask),
        ])

        let prefillStart = CFAbsoluteTimeGetCurrent()
        let decoderOutput = try models.decoder.prediction(from: decoderInput, using: state)
        guard let prefillHidden = decoderOutput.featureValue(for: "output_hidden")?.multiArrayValue else {
            throw NSError(domain: "CanaryQwen", code: 16, userInfo: [
                NSLocalizedDescriptionKey: "Missing output_hidden from Canary decoder",
            ])
        }
        timing.decoderPrefillMs = (CFAbsoluteTimeGetCurrent() - prefillStart) * 1000

        let lastHidden = try sliceLastHidden(prefillHidden, seqLen: totalSeq)
        let lmPrefillStart = CFAbsoluteTimeGetCurrent()
        let lmPrefillInput = try MLDictionaryFeatureProvider(dictionary: [
            "hidden_states": MLFeatureValue(multiArray: lastHidden)
        ])
        let lmPrefillOutput = try models.lmHead.prediction(from: lmPrefillInput)
        guard let prefillLogits = lmPrefillOutput.featureValue(for: "logits")?.multiArrayValue else {
            throw NSError(domain: "CanaryQwen", code: 17, userInfo: [
                NSLocalizedDescriptionKey: "Missing logits from Canary lm head",
            ])
        }
        timing.lmHeadPrefillMs = (CFAbsoluteTimeGetCurrent() - lmPrefillStart) * 1000

        var nextToken = argmax(logits: prefillLogits)
        var generatedIds: [Int] = []
        var currentPosition = totalSeq

        let decodeHidden = try MLMultiArray(shape: [1, 1, NSNumber(value: hiddenSize)], dataType: .float32)
        let decodeHiddenPtr = decodeHidden.dataPointer.bindMemory(to: Float.self, capacity: hiddenSize)
        let decodeCos = try MLMultiArray(shape: [1, 1, NSNumber(value: CanaryQwenConfig.headDim)], dataType: .float32)
        let decodeSin = try MLMultiArray(shape: [1, 1, NSNumber(value: CanaryQwenConfig.headDim)], dataType: .float32)
        let decodeCosPtr = decodeCos.dataPointer.bindMemory(to: Float.self, capacity: CanaryQwenConfig.headDim)
        let decodeSinPtr = decodeSin.dataPointer.bindMemory(to: Float.self, capacity: CanaryQwenConfig.headDim)

        for _ in 0..<maxNewTokens {
            if CanaryQwenConfig.stopTokenIds.contains(nextToken) { break }
            generatedIds.append(nextToken)

            let nextEmbedding = models.embeddings.embedding(for: nextToken)
            nextEmbedding.withUnsafeBufferPointer { src in
                _ = memcpy(decodeHiddenPtr, src.baseAddress!, hiddenSize * MemoryLayout<Float>.stride)
            }
            rope.fill(position: currentPosition, cosPtr: decodeCosPtr, sinPtr: decodeSinPtr)
            guard let decodeMask = decodeMasks[currentPosition + 1] else {
                break
            }

            let decodeInput = try MLDictionaryFeatureProvider(dictionary: [
                "hidden_states": MLFeatureValue(multiArray: decodeHidden),
                "position_cos": MLFeatureValue(multiArray: decodeCos),
                "position_sin": MLFeatureValue(multiArray: decodeSin),
                "attention_mask": MLFeatureValue(multiArray: decodeMask),
            ])

            let decodeStart = CFAbsoluteTimeGetCurrent()
            let decodeOutput = try models.decoder.prediction(from: decodeInput, using: state)
            guard let decodeHiddenOut = decodeOutput.featureValue(for: "output_hidden")?.multiArrayValue else {
                throw NSError(domain: "CanaryQwen", code: 18, userInfo: [
                    NSLocalizedDescriptionKey: "Missing decode output_hidden from Canary decoder",
                ])
            }
            timing.decoderDecodeMs += (CFAbsoluteTimeGetCurrent() - decodeStart) * 1000

            let lmStart = CFAbsoluteTimeGetCurrent()
            let lmInput = try MLDictionaryFeatureProvider(dictionary: [
                "hidden_states": MLFeatureValue(multiArray: decodeHiddenOut)
            ])
            let lmOutput = try models.lmHead.prediction(from: lmInput)
            guard let logits = lmOutput.featureValue(for: "logits")?.multiArrayValue else {
                throw NSError(domain: "CanaryQwen", code: 19, userInfo: [
                    NSLocalizedDescriptionKey: "Missing decode logits from Canary lm head",
                ])
            }
            timing.lmHeadDecodeMs += (CFAbsoluteTimeGetCurrent() - lmStart) * 1000

            nextToken = argmax(logits: logits)
            currentPosition += 1
        }

        return (decodeTokens(generatedIds), timing)
    }

    private func tokenBudget(for chunkSeconds: Double) -> Int {
        let estimate = Int(ceil(chunkSeconds * 6.0)) + 8
        return min(CanaryQwenConfig.maxNewTokens, max(8, estimate))
    }

    private func scheduleChunks(mel: [[Float]]) -> [(CanaryChunkSpan, [[Float]])] {
        guard let totalFrames = mel.first?.count else { return [] }
        if totalFrames <= CanaryQwenConfig.encoderFrames {
            let span = CanaryChunkSpan(index: 0, startFrame: 0, endFrame: totalFrames, durationS: Double(totalFrames) * 0.01)
            return [(span, mel)]
        }

        let stride = CanaryQwenConfig.encoderFrames - CanaryQwenConfig.chunkOverlapFrames
        let lastFullStart = max(totalFrames - CanaryQwenConfig.encoderFrames, 0)
        var starts: [Int] = []
        var start = 0
        while true {
            starts.append(start)
            let nextStart = start + stride
            if nextStart + CanaryQwenConfig.encoderFrames >= totalFrames {
                if lastFullStart > starts.last! {
                    starts.append(lastFullStart)
                }
                break
            }
            start = nextStart
        }

        var scheduled: [(CanaryChunkSpan, [[Float]])] = []
        for (index, chunkStart) in starts.enumerated() {
            let end = min(chunkStart + CanaryQwenConfig.encoderFrames, totalFrames)
            let span = CanaryChunkSpan(index: index, startFrame: chunkStart, endFrame: end, durationS: Double(end - chunkStart) * 0.01)
            let chunk = mel.map { Array($0[chunkStart..<end]) }
            scheduled.append((span, chunk))
        }
        return scheduled
    }

    private func mergeChunkTranscripts(_ texts: [String]) -> String {
        var mergedWords: [String] = []
        for text in texts {
            let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
            if words.isEmpty { continue }
            if mergedWords.isEmpty {
                mergedWords.append(contentsOf: words)
                continue
            }

            let lowerExisting = mergedWords.map(normalizeMergeToken)
            let lowerNew = words.map(normalizeMergeToken)
            let maxOverlap = min(lowerExisting.count, lowerNew.count, 12)
            var overlap = 0
            if maxOverlap > 0 {
                for k in stride(from: maxOverlap, through: 1, by: -1) {
                    if Array(lowerExisting.suffix(k)) == Array(lowerNew.prefix(k)) {
                        overlap = k
                        break
                    }
                }
            }
            if overlap > 0 && overlap < words.count && !mergedWords.isEmpty {
                mergedWords[mergedWords.count - 1] = mergedWords.last!.replacingOccurrences(of: #"[,.!?;:]+$"#, with: "", options: .regularExpression)
            }
            mergedWords.append(contentsOf: words.dropFirst(overlap))
        }
        return mergedWords.joined(separator: " ")
    }

    private func normalizeMergeToken(_ token: String) -> String {
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        let scalars = token.unicodeScalars.filter { !punctuation.contains($0) }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }

    private func decodeTokens(_ tokenIds: [Int]) -> String {
        var pieces: [String] = []
        pieces.reserveCapacity(tokenIds.count)
        for tokenId in tokenIds {
            if let piece = models.vocabulary[tokenId] {
                pieces.append(piece)
            }
        }
        let raw = pieces.joined()
        let bytes = raw.unicodeScalars.compactMap { scalar -> UInt8? in
            Self.bpeUnicodeToByte[scalar.value]
        }
        let decoded = String(bytes: bytes, encoding: .utf8) ?? String(raw.filter(\.isASCII))
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let bpeUnicodeToByte: [UInt32: UInt8] = {
        var printable = [Int]()
        printable.append(contentsOf: 33...126)
        printable.append(contentsOf: 161...172)
        printable.append(contentsOf: 174...255)
        let printableSet = Set(printable)

        var mapping: [UInt32: UInt8] = [:]
        for value in printable {
            mapping[UInt32(value)] = UInt8(value)
        }
        var extra: UInt32 = 256
        for value in 0...255 where !printableSet.contains(value) {
            mapping[extra] = UInt8(value)
            extra += 1
        }
        return mapping
    }()

    private func argmax(logits: MLMultiArray) -> Int {
        let count = logits.count
        var maxValue = -Float.infinity
        var maxIndex = 0
        for idx in 0..<count {
            let value = logits[idx].floatValue
            if value > maxValue {
                maxValue = value
                maxIndex = idx
            }
        }
        return maxIndex
    }

    private func copyProjectedAudioEmbeds(_ source: MLMultiArray, to destination: UnsafeMutablePointer<Float>) {
        let count = source.count
        for idx in 0..<count {
            destination[idx] = source[idx].floatValue
        }
    }

    private func createEncoderInput(_ melChunk: [[Float]]) throws -> MLMultiArray {
        let paddedFrames = CanaryQwenConfig.encoderFrames
        let array = try MLMultiArray(shape: [1, 128, NSNumber(value: paddedFrames)], dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: 128 * paddedFrames)
        ptr.initialize(repeating: 0, count: 128 * paddedFrames)
        for melBin in 0..<128 {
            let row = melChunk[melBin]
            for t in 0..<min(row.count, paddedFrames) {
                ptr[(melBin * paddedFrames) + t] = row[t]
            }
        }
        return array
    }

    private func createPositionArray(values: [Float], seqLen: Int) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: seqLen), NSNumber(value: CanaryQwenConfig.headDim)], dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: values.count)
        values.withUnsafeBufferPointer { src in
            _ = memcpy(ptr, src.baseAddress!, values.count * MemoryLayout<Float>.stride)
        }
        return array
    }

    private static func createPrefillMask(seqLen: Int) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, 1, NSNumber(value: seqLen), NSNumber(value: seqLen)], dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: seqLen * seqLen)
        for i in 0..<seqLen {
            for j in 0..<seqLen {
                ptr[(i * seqLen) + j] = j > i ? Float(-1e9) : 0.0
            }
        }
        return array
    }

    private static func createDecodeMask(endStep: Int) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, 1, 1, NSNumber(value: endStep)], dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: endStep)
        ptr.initialize(repeating: 0, count: endStep)
        return array
    }

    private func slicePrefillMask(seqLen: Int) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, 1, NSNumber(value: seqLen), NSNumber(value: seqLen)], dataType: .float32)
        let src = prefillCausalMask.dataPointer.bindMemory(to: Float.self, capacity: CanaryQwenConfig.maxCacheLen * CanaryQwenConfig.maxCacheLen)
        let dst = array.dataPointer.bindMemory(to: Float.self, capacity: seqLen * seqLen)
        for i in 0..<seqLen {
            for j in 0..<seqLen {
                dst[(i * seqLen) + j] = src[(i * CanaryQwenConfig.maxCacheLen) + j]
            }
        }
        return array
    }

    private func sliceLastHidden(_ hidden: MLMultiArray, seqLen: Int) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, 1, NSNumber(value: CanaryQwenConfig.hiddenSize)], dataType: .float32)
        let dst = array.dataPointer.bindMemory(to: Float.self, capacity: CanaryQwenConfig.hiddenSize)
        let offset = (seqLen - 1) * CanaryQwenConfig.hiddenSize
        for i in 0..<CanaryQwenConfig.hiddenSize {
            dst[i] = hidden[offset + i].floatValue
        }
        return array
    }
}

/// Native Swift transcription backend using the split Canary CoreML model stack.
/// Uses Swift-side embedding lookup and a stateful decoder. Requires macOS 15+ for MLState support.
@available(macOS 15, *)
actor CanaryQwenTranscriber {
    private var manager: CanaryQwenManager?

    enum TranscriberError: Error, LocalizedError {
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "Canary Qwen models not loaded. Call loadModels() first."
            }
        }
    }

    func loadModels(progress: ((Double, String?) -> Void)? = nil) async throws {
        if manager != nil { return }
        fputs("[canary-qwen] downloading/loading models...\n", stderr)
        let modelDir = try await CanaryQwenModelStore.resolvedDirectory(progress: progress)
        let models = try await CanaryQwenModels.load(from: modelDir)
        let manager = try CanaryQwenManager(models: models)
        self.manager = manager
        fputs("[canary-qwen] models loaded, running warmup inference...\n", stderr)
        let warmupSamples = [Float](repeating: 0, count: 16_000)
        _ = try? await manager.transcribe(audioSamples: warmupSamples)
        fputs("[canary-qwen] warmup complete, ready\n", stderr)
    }

    func transcribe(wavURL: URL) async throws -> (text: String, processingTime: Double) {
        guard let manager else { throw TranscriberError.notLoaded }
        let start = CFAbsoluteTimeGetCurrent()
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(wavURL)
        let text = try await manager.transcribe(audioSamples: samples)
        let processingTime = CFAbsoluteTimeGetCurrent() - start
        return (text, processingTime)
    }

    func shutdown() {
        manager = nil
    }
}
