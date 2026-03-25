import FluidAudio
import Foundation
import MuesliCore
import os

final class MeetingChunkCollector {
    private struct State {
        var tasks: [Task<SpeechSegment?, Never>] = []
        var isClosed = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func add(_ task: Task<SpeechSegment?, Never>) -> Bool {
        lock.withLock { state in
            guard !state.isClosed else { return false }
            state.tasks.append(task)
            return true
        }
    }

    func closeAndDrainSortedSegments() async -> [SpeechSegment] {
        let tasksToAwait = lock.withLock { state in
            state.isClosed = true
            let pendingTasks = state.tasks
            state.tasks.removeAll()
            return pendingTasks
        }

        var segments: [SpeechSegment] = []
        for task in tasksToAwait {
            if let segment = await task.value {
                segments.append(segment)
            }
        }

        return segments.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }
    }

    func cancelAll() {
        let tasksToCancel = lock.withLock { state in
            state.isClosed = true
            let pendingTasks = state.tasks
            state.tasks.removeAll()
            return pendingTasks
        }

        tasksToCancel.forEach { $0.cancel() }
    }
}

struct MeetingSessionResult {
    let title: String
    let calendarEventID: String?
    let startTime: Date
    let endTime: Date
    let durationSeconds: Double
    let rawTranscript: String
    let formattedNotes: String
    let micAudioPath: String?
    let systemAudioPath: String?
}

final class MeetingSession {
    private let title: String
    private let calendarEventID: String?
    private let backend: BackendOption
    private let runtime: RuntimePaths
    private let config: AppConfig
    private let transcriptionCoordinator: TranscriptionCoordinator
    private let systemAudioRecorder = SystemAudioRecorder()

    /// Streaming mic recorder with real-time buffer access (AVAudioEngine)
    private var streamingMicRecorder = StreamingMicRecorder()
    /// VAD controller for speech-boundary chunk rotation
    private var vadController: StreamingVadController?
    private let micChunkCollector = MeetingChunkCollector()
    private let systemChunkCollector = MeetingChunkCollector()
    /// Track chunk start times for timestamp offsets
    private var currentChunkStartTime: Date?

    // MARK: - Incremental transcript access (for mid-session clipboard copy)

    /// Resolved mic segments accumulated as chunks complete transcription.
    private let resolvedMicSegments = OSAllocatedUnfairLock(initialState: [SpeechSegment]())
    /// Resolved system audio segments accumulated as chunks complete transcription.
    private let resolvedSystemSegments = OSAllocatedUnfairLock(initialState: [SpeechSegment]())

    /// Current mic power level for waveform visualization.
    func currentPower() -> Float {
        streamingMicRecorder.currentPower()
    }

    /// Number of resolved segments (cheap check to detect changes without copying arrays).
    func segmentCounts() -> (mic: Int, system: Int) {
        (resolvedMicSegments.withLock { $0.count },
         resolvedSystemSegments.withLock { $0.count })
    }

    /// Snapshot of all resolved segments so far (for live transcript display).
    func allSegments() -> (mic: [SpeechSegment], system: [SpeechSegment]) {
        (resolvedMicSegments.withLock { Array($0) },
         resolvedSystemSegments.withLock { Array($0) })
    }

    /// Returns the formatted transcript delta since the given offsets, plus new offsets.
    /// Used for mid-session clipboard copy (e.g., "send to Claude" hotkey).
    func transcriptDelta(
        micOffset: Int,
        systemOffset: Int
    ) -> (text: String, newMicOffset: Int, newSystemOffset: Int) {
        let meetingStart = self.startTime ?? Date()

        let micSegs = resolvedMicSegments.withLock { Array($0.dropFirst(micOffset)) }
        let sysSegs = resolvedSystemSegments.withLock { Array($0.dropFirst(systemOffset)) }

        let newMicOffset = micOffset + micSegs.count
        let newSystemOffset = systemOffset + sysSegs.count

        guard !micSegs.isEmpty || !sysSegs.isEmpty else {
            return (text: "", newMicOffset: newMicOffset, newSystemOffset: newSystemOffset)
        }

        let text = TranscriptFormatter.merge(
            micSegments: micSegs,
            systemSegments: sysSegs,
            meetingStart: meetingStart
        )
        return (text: text, newMicOffset: newMicOffset, newSystemOffset: newSystemOffset)
    }

    private(set) var startTime: Date?
    private(set) var isRecording = false

    init(
        title: String,
        calendarEventID: String?,
        backend: BackendOption,
        runtime: RuntimePaths,
        config: AppConfig,
        transcriptionCoordinator: TranscriptionCoordinator
    ) {
        self.title = title
        self.calendarEventID = calendarEventID
        self.backend = backend
        self.runtime = runtime
        self.config = config
        self.transcriptionCoordinator = transcriptionCoordinator
    }

    private var serializedCustomWords: [[String: Any]] {
        config.customWords.map { word in
            var dict: [String: Any] = ["word": word.word]
            if let replacement = word.replacement {
                dict["replacement"] = replacement
            }
            return dict
        }
    }

    func start() async throws {
        try streamingMicRecorder.prepare()
        try streamingMicRecorder.start()
        try await systemAudioRecorder.start()
        let now = Date()
        startTime = now
        currentChunkStartTime = now
        isRecording = true

        // Set up VAD-driven chunk rotation
        Task { [weak self] in
            guard let self else { return }
            if let vadManager = await self.transcriptionCoordinator.getVadManager() {
                let controller = StreamingVadController(vadManager: vadManager)
                controller.onChunkBoundary = { [weak self] in
                    self?.rotateChunk()
                }
                controller.start()
                self.vadController = controller

                // Wire mic audio to VAD
                self.streamingMicRecorder.onAudioBuffer = { [weak controller] samples in
                    controller?.processAudio(samples)
                }
                fputs("[meeting] started with VAD-driven chunk rotation\n", stderr)
            } else {
                fputs("[meeting] VAD not available, using max-duration fallback only\n", stderr)
            }
        }
    }

    /// Abandon the recording — stop everything, delete temp files, don't transcribe.
    func discard() {
        isRecording = false
        vadController?.stop()
        vadController = nil
        streamingMicRecorder.cancel()
        if let url = systemAudioRecorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        micChunkCollector.cancelAll()
        systemChunkCollector.cancelAll()
        fputs("[meeting] recording discarded\n", stderr)
    }

    func stop() async throws -> MeetingSessionResult {
        isRecording = false
        let meetingStart = self.startTime ?? Date()
        let endTime = Date()
        var micSegments: [SpeechSegment] = []

        // Stop VAD controller
        vadController?.stop()
        vadController = nil

        // Stop mic and get last chunk
        let lastMicURL = streamingMicRecorder.stop()
        let lastChunkStart = currentChunkStartTime ?? meetingStart

        // Stop system audio
        let systemAudioURL = systemAudioRecorder.stop()

        // Transcribe last mic chunk
        if let lastMicURL {
            let chunkOffset = lastChunkStart.timeIntervalSince(meetingStart)
            fputs("[meeting] transcribing final mic chunk (offset=\(String(format: "%.0f", chunkOffset))s)\n", stderr)
            do {
                let result = try await transcriptionCoordinator.transcribeMeetingChunk(at: lastMicURL, backend: backend, customWords: serializedCustomWords)
                if !result.text.isEmpty {
                    micSegments.append(SpeechSegment(start: chunkOffset, end: chunkOffset, text: result.text))
                }
            } catch {
                fputs("[meeting] final mic chunk transcription failed: \(error)\n", stderr)
            }
            try? FileManager.default.removeItem(at: lastMicURL)
        }

        // Transcribe system audio (batch — this is the only wait after meeting ends)
        let systemResult: SpeechTranscriptionResult
        var diarizationSegments: [TimedSpeakerSegment]?
        if let systemAudioURL {
            fputs("[meeting] transcribing system audio (batch)\n", stderr)
            systemResult = try await transcriptionCoordinator.transcribeMeeting(at: systemAudioURL, backend: backend, customWords: serializedCustomWords)

            // Run speaker diarization on system audio (batch post-processing)
            if let diarizationResult = try? await transcriptionCoordinator.diarizeSystemAudio(at: systemAudioURL) {
                diarizationSegments = diarizationResult.segments
            }

            try? FileManager.default.removeItem(at: systemAudioURL)
        } else {
            systemResult = SpeechTranscriptionResult(text: "", segments: [])
        }

        micSegments.append(contentsOf: await micChunkCollector.closeAndDrainSortedSegments())
        micSegments.sort { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }

        // Drain system chunks (discard — batch transcription above is authoritative)
        _ = await systemChunkCollector.closeAndDrainSortedSegments()

        fputs("[meeting] \(micSegments.count) mic chunks transcribed during meeting\n", stderr)

        let rawTranscript = TranscriptFormatter.merge(
            micSegments: micSegments,
            systemSegments: systemResult.segments,
            diarizationSegments: diarizationSegments,
            meetingStart: meetingStart
        )

        // Auto-generate meeting title from transcript
        let generatedTitle: String
        if let autoTitle = await MeetingSummaryClient.generateTitle(transcript: rawTranscript, config: config),
           !autoTitle.isEmpty {
            generatedTitle = autoTitle
            fputs("[meeting] auto-generated title: \(generatedTitle)\n", stderr)
        } else {
            generatedTitle = title
        }

        let formattedNotes = await MeetingSummaryClient.summarize(
            transcript: rawTranscript,
            meetingTitle: generatedTitle,
            config: config
        )

        return MeetingSessionResult(
            title: generatedTitle,
            calendarEventID: calendarEventID,
            startTime: meetingStart,
            endTime: endTime,
            durationSeconds: max(endTime.timeIntervalSince(meetingStart), 0),
            rawTranscript: rawTranscript,
            formattedNotes: formattedNotes,
            micAudioPath: nil,
            systemAudioPath: nil
        )
    }

    /// Called by VAD on speech boundaries or max-duration fallback.
    /// Rotates both mic and system audio files and sends completed chunks for transcription.
    private func rotateChunk() {
        guard isRecording else { return }
        let meetingStart = self.startTime ?? Date()
        let chunkStart = currentChunkStartTime ?? meetingStart

        // Rotate both files — no gap, taps keep running
        let micChunkURL = streamingMicRecorder.rotateFile()
        let systemChunkURL = systemAudioRecorder.rotateFile()
        currentChunkStartTime = Date()

        let chunkOffset = chunkStart.timeIntervalSince(meetingStart)
        let backend = self.backend

        fputs("[meeting] rotating chunk at offset=\(String(format: "%.0f", chunkOffset))s\n", stderr)

        // Transcribe mic chunk
        var micTask: Task<SpeechSegment?, Never>?
        if let micChunkURL {
            let task = Task { [weak self] () -> SpeechSegment? in
                defer {
                    try? FileManager.default.removeItem(at: micChunkURL)
                }
                guard let self else { return nil }
                do {
                    if Task.isCancelled { return nil }
                    let result = try await self.transcriptionCoordinator.transcribeMeetingChunk(at: micChunkURL, backend: backend, customWords: self.serializedCustomWords)
                    if !result.text.isEmpty {
                        fputs("[meeting] mic chunk transcribed: \"\(String(result.text.prefix(60)))...\"\n", stderr)
                        let segment = SpeechSegment(start: chunkOffset, end: chunkOffset, text: result.text)
                        self.resolvedMicSegments.withLock { $0.append(segment) }
                        return segment
                    }
                } catch {
                    fputs("[meeting] mic chunk transcription failed: \(error)\n", stderr)
                }
                return nil
            }
            micTask = task
            if !micChunkCollector.add(task) {
                task.cancel()
            }
        }

        // Transcribe system audio chunk — serialized after mic to avoid concurrent
        // CoreML predictions whose MLMultiArray buffers race with autorelease pool
        // cleanup on the cooperative thread pool (causes EXC_BAD_ACCESS).
        if let systemChunkURL {
            let precedingMicTask = micTask
            let systemTask = Task { [weak self] () -> SpeechSegment? in
                // Wait for mic transcription to finish first
                if let precedingMicTask {
                    _ = await precedingMicTask.value
                }
                defer {
                    try? FileManager.default.removeItem(at: systemChunkURL)
                }
                guard let self else { return nil }
                do {
                    if Task.isCancelled { return nil }
                    let result = try await self.transcriptionCoordinator.transcribeMeetingChunk(at: systemChunkURL, backend: backend, customWords: self.serializedCustomWords)
                    if !result.text.isEmpty {
                        fputs("[meeting] system chunk transcribed: \"\(String(result.text.prefix(60)))...\"\n", stderr)
                        let segment = SpeechSegment(start: chunkOffset, end: chunkOffset, text: result.text)
                        self.resolvedSystemSegments.withLock { $0.append(segment) }
                        return segment
                    }
                } catch {
                    fputs("[meeting] system chunk transcription failed: \(error)\n", stderr)
                }
                return nil
            }
            if !systemChunkCollector.add(systemTask) {
                systemTask.cancel()
            }
        }
    }
}
