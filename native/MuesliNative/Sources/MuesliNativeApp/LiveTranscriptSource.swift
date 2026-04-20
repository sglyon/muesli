import FluidAudio
import Foundation
import MuesliCore

/// Resolved-per-chunk payload emitted by `MeetingSession.onChunkResolved`.
/// Lets the coordinator accumulate live-transcript state without MeetingSession
/// owning any of it.
struct MeetingChunkResolution {
    let mic: [SpeechSegment]
    let system: [SpeechSegment]
    let diarization: [TimedSpeakerSegment]
    let chunkOffset: Double
}

/// Everything the live transcript panel / clipboard hotkey need from the
/// accumulator. Implemented by `LiveCoachCoordinator`; lets us test the panel
/// without a real `MeetingSession`.
protocol LiveTranscriptSource: AnyObject {
    var meetingStartTime: Date? { get }
    func segmentCounts() -> (mic: Int, system: Int)
    func allSegments() -> (mic: [SpeechSegment], system: [SpeechSegment], diarization: [TimedSpeakerSegment], labelMap: [String: String])
    func transcriptDelta(micOffset: Int, systemOffset: Int) -> (text: String, newMicOffset: Int, newSystemOffset: Int)
}
