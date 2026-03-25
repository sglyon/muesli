import FluidAudio
import Foundation
import MuesliCore

enum TranscriptFormatter {
    /// Backward-compatible merge without diarization.
    static func merge(micSegments: [SpeechSegment], systemSegments: [SpeechSegment], meetingStart: Date) -> String {
        merge(micSegments: micSegments, systemSegments: systemSegments, diarizationSegments: nil, meetingStart: meetingStart)
    }

    /// Merge with optional speaker diarization for system audio.
    static func merge(
        micSegments: [SpeechSegment],
        systemSegments: [SpeechSegment],
        diarizationSegments: [TimedSpeakerSegment]?,
        speakerLabelMap: [String: String]? = nil,
        meetingStart: Date
    ) -> String {
        // Detect if both streams captured the same audio (e.g., mic picks up speakers).
        // When overlap is high, use system audio + diarization as the single source
        // (diarization provides proper speaker labels like "Speaker 1", "Speaker 2").
        // When overlap is low, use both streams: mic = "You", system = diarized speakers.
        let overlapRatio = streamOverlapRatio(micSegments: micSegments, systemSegments: systemSegments)
        let streamsAreDuplicated = overlapRatio > 0.5

        let tagged: [TaggedSegment]

        if streamsAreDuplicated && !systemSegments.isEmpty {
            // Single-stream mode: both captured the same audio, so use system + diarization
            // for proper speaker attribution instead of labeling everything "You".
            let diarCount = diarizationSegments?.count ?? 0
            fputs("[transcript] streams overlap \(String(format: "%.0f", overlapRatio * 100))%% — using system audio with diarization (\(diarCount) diar segments)\n", stderr)
            tagged = tagSystemSegments(systemSegments, diarizationSegments: diarizationSegments, speakerLabelMap: speakerLabelMap)
        } else {
            // Dual-stream mode: streams captured different audio (headphones/separate sources).
            // Mic is the user's voice, system is everyone else.
            let taggedMic = micSegments.map { TaggedSegment(segment: $0, speaker: "You") }
            let taggedSystem = tagSystemSegments(systemSegments, diarizationSegments: diarizationSegments, speakerLabelMap: speakerLabelMap)
            tagged = (taggedMic + taggedSystem).sorted { $0.segment.start < $1.segment.start }
        }

        // Consolidate consecutive segments from the same speaker into single lines
        let consolidated = consolidate(tagged)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"

        return consolidated.map { taggedSegment in
            let timestamp = meetingStart.addingTimeInterval(taggedSegment.segment.start)
            let text = taggedSegment.segment.text.trimmingCharacters(in: .whitespaces)
            return "[\(formatter.string(from: timestamp))] \(taggedSegment.speaker): \(text)"
        }.joined(separator: "\n")
    }

    /// Merge consecutive segments from the same speaker into single entries.
    /// Prevents token-level fragmentation (e.g., each token as a separate line).
    private static func consolidate(_ segments: [TaggedSegment]) -> [TaggedSegment] {
        guard !segments.isEmpty else { return [] }

        var result: [TaggedSegment] = []
        var currentSpeaker = segments[0].speaker
        var currentStart = segments[0].segment.start
        var currentEnd = segments[0].segment.end
        var currentText = segments[0].segment.text

        for seg in segments.dropFirst() {
            if seg.speaker == currentSpeaker {
                // Same speaker — accumulate text
                currentText += seg.segment.text
                currentEnd = max(currentEnd, seg.segment.end)
            } else {
                // Speaker changed — emit accumulated segment
                result.append(TaggedSegment(
                    segment: SpeechSegment(start: currentStart, end: currentEnd, text: currentText),
                    speaker: currentSpeaker
                ))
                currentSpeaker = seg.speaker
                currentStart = seg.segment.start
                currentEnd = seg.segment.end
                currentText = seg.segment.text
            }
        }
        // Emit last segment
        result.append(TaggedSegment(
            segment: SpeechSegment(start: currentStart, end: currentEnd, text: currentText),
            speaker: currentSpeaker
        ))

        return result
    }

    /// Tag system segments with speaker labels from diarization (or "Others" if unavailable).
    /// When `speakerLabelMap` is provided (live transcript), uses it directly for stable labels.
    /// When nil (batch transcript at meeting end), builds the map from diarization segment order.
    private static func tagSystemSegments(
        _ segments: [SpeechSegment],
        diarizationSegments: [TimedSpeakerSegment]?,
        speakerLabelMap externalMap: [String: String]? = nil
    ) -> [TaggedSegment] {
        if let diarizationSegments, !diarizationSegments.isEmpty {
            let labelMap: [String: String]
            if let externalMap, !externalMap.isEmpty {
                labelMap = externalMap
            } else {
                // Build map from scratch (batch path at meeting end)
                var builtMap: [String: String] = [:]
                var nextSpeakerNumber = 1
                for seg in diarizationSegments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
                    if builtMap[seg.speakerId] == nil {
                        builtMap[seg.speakerId] = "Speaker \(nextSpeakerNumber)"
                        nextSpeakerNumber += 1
                    }
                }
                labelMap = builtMap
            }
            return segments.map { segment in
                let speaker = findSpeaker(for: segment, in: diarizationSegments, labelMap: labelMap)
                return TaggedSegment(segment: segment, speaker: speaker)
            }
        } else {
            return segments.map { TaggedSegment(segment: $0, speaker: "Others") }
        }
    }

    /// Fraction of system segments that have a near-duplicate in the mic stream (0.0–1.0).
    /// A high ratio means both streams captured the same audio.
    private static func streamOverlapRatio(
        micSegments: [SpeechSegment],
        systemSegments: [SpeechSegment]
    ) -> Double {
        guard !systemSegments.isEmpty, !micSegments.isEmpty else { return 0 }

        let duplicateCount = systemSegments.filter { sysSegment in
            let tolerance: Double = 10.0
            return micSegments.contains { micSegment in
                abs(micSegment.start - sysSegment.start) <= tolerance
                    && wordOverlap(micSegment.text, sysSegment.text) > 0.5
            }
        }.count

        return Double(duplicateCount) / Double(systemSegments.count)
    }

    /// Jaccard similarity of word sets (intersection / union).
    private static func wordOverlap(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let wordsB = Set(b.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 0 }
        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count
        return Double(intersection) / Double(union)
    }

    /// Find the best-matching speaker for an ASR segment by time overlap with diarization segments.
    private static func findSpeaker(
        for segment: SpeechSegment,
        in diarizationSegments: [TimedSpeakerSegment],
        labelMap: [String: String]
    ) -> String {
        let segStart = Float(segment.start)
        let segEnd = Float(max(segment.end, segment.start + 0.1)) // ensure non-zero duration

        var bestOverlap: Float = 0
        var bestSpeakerId: String?

        for diarSeg in diarizationSegments {
            let overlapStart = max(segStart, diarSeg.startTimeSeconds)
            let overlapEnd = min(segEnd, diarSeg.endTimeSeconds)
            let overlap = max(0, overlapEnd - overlapStart)

            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeakerId = diarSeg.speakerId
            }
        }

        if let bestSpeakerId, bestOverlap > 0 {
            return labelMap[bestSpeakerId] ?? "Others"
        }
        return "Others"
    }
}

private struct TaggedSegment {
    let segment: SpeechSegment
    let speaker: String
}
