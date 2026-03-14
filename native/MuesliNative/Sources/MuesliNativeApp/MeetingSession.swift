import Foundation

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
    private let microphoneRecorder = MicrophoneRecorder()
    private let systemAudioRecorder: SystemAudioRecorder

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
        self.systemAudioRecorder = SystemAudioRecorder(toolURL: runtime.systemAudioTool)
    }

    func start() throws {
        try microphoneRecorder.prepare()
        try microphoneRecorder.start()
        try systemAudioRecorder.start()
        startTime = Date()
        isRecording = true
    }

    func stop() async throws -> MeetingSessionResult {
        isRecording = false
        let startTime = self.startTime ?? Date()
        let endTime = Date()

        let micAudioURL = microphoneRecorder.stop()
        let systemAudioURL = systemAudioRecorder.stop()

        let micResult: SpeechTranscriptionResult
        if let micAudioURL {
            micResult = try await transcriptionCoordinator.transcribeMeeting(at: micAudioURL, backend: backend)
        } else {
            micResult = SpeechTranscriptionResult(text: "", segments: [])
        }

        let systemResult: SpeechTranscriptionResult
        if let systemAudioURL {
            systemResult = try await transcriptionCoordinator.transcribeMeeting(at: systemAudioURL, backend: backend)
        } else {
            systemResult = SpeechTranscriptionResult(text: "", segments: [])
        }

        let rawTranscript = TranscriptFormatter.merge(
            micSegments: micResult.segments,
            systemSegments: systemResult.segments,
            meetingStart: startTime
        )
        let formattedNotes = await MeetingSummaryClient.summarize(
            transcript: rawTranscript,
            meetingTitle: title,
            config: config
        )

        return MeetingSessionResult(
            title: title,
            calendarEventID: calendarEventID,
            startTime: startTime,
            endTime: endTime,
            durationSeconds: max(endTime.timeIntervalSince(startTime), 0),
            rawTranscript: rawTranscript,
            formattedNotes: formattedNotes,
            micAudioPath: micAudioURL?.path,
            systemAudioPath: systemAudioURL?.path
        )
    }
}
