import AppKit
import FluidAudio
import Foundation
import MuesliCore
import os

/// Owns everything specific to the Live Coach / live transcript features:
/// sidecar lifecycle, transcript hotkeys, panel toggle, coach-memory reset,
/// and the accumulator populated from `MeetingSession.onChunkResolved`.
///
/// Isolated in one type so MuesliController stays close to upstream — future
/// upstream merges touch MuesliController, not our feature code.
@MainActor
final class LiveCoachCoordinator: LiveTranscriptSource {
    private let configProvider: () -> AppConfig
    private weak var indicator: FloatingIndicatorController?
    private weak var statusBarController: StatusBarController?
    private let isMeetingActive: () -> Bool

    private(set) var liveCoachSidecar: LiveCoachSidecar?
    private var liveTranscriptController: LiveTranscriptPanelController?
    private var activeMeetingTitle: String = "Meeting"
    private var activeMeetingID: String = ""
    private(set) var meetingStartTime: Date?

    private var transcriptKeyMonitorGlobal: Any?
    private var transcriptKeyMonitorLocal: Any?
    private var lastMicOffset = 0
    private var lastSystemOffset = 0

    // Live-transcript accumulator. Populated from MeetingSession.onChunkResolved
    // so MeetingSession itself carries none of this state.
    private let resolvedMicSegments = OSAllocatedUnfairLock(initialState: [SpeechSegment]())
    private let resolvedSystemSegments = OSAllocatedUnfairLock(initialState: [SpeechSegment]())
    private let resolvedDiarizationSegments = OSAllocatedUnfairLock(initialState: [TimedSpeakerSegment]())
    private let speakerLabelMap = OSAllocatedUnfairLock(initialState: [String: String]())
    private let nextSpeakerNumber = OSAllocatedUnfairLock(initialState: 1)

    init(
        configProvider: @escaping () -> AppConfig,
        isMeetingActive: @escaping () -> Bool
    ) {
        self.configProvider = configProvider
        self.isMeetingActive = isMeetingActive
    }

    func configure(indicator: FloatingIndicatorController, statusBarController: StatusBarController) {
        self.indicator = indicator
        self.statusBarController = statusBarController
    }

    // MARK: - App lifecycle

    /// Warm up the sidecar at app launch so the panel doesn't race the
    /// handshake when the user opens it the first time.
    func applicationDidStart() {
        if configProvider().liveCoach.enabled {
            launchSidecarIfNeeded()
        }
    }

    // MARK: - Meeting lifecycle

    func meetingWillStart(session: MeetingSession, title: String) {
        activeMeetingTitle = title
        activeMeetingID = UUID().uuidString
        meetingStartTime = nil
        resetAccumulator()

        session.onChunkResolved = { [weak self] resolution in
            self?.handleChunkResolved(resolution)
        }

        if configProvider().liveCoach.enabled {
            launchSidecarIfNeeded()
        }
    }

    func meetingDidStart(startTime: Date) {
        meetingStartTime = startTime
        installTranscriptHotkey()
    }

    func meetingWillStop() {
        removeTranscriptHotkey()
        liveTranscriptController?.hide()
    }

    // MARK: - Sidecar

    func launchSidecarIfNeeded() {
        if liveCoachSidecar != nil { return }
        let sidecar = LiveCoachSidecar()
        liveCoachSidecar = sidecar
        Task {
            do {
                try await sidecar.launch()
            } catch {
                fputs("[muesli-native] live coach sidecar launch failed: \(error)\n", stderr)
                self.liveCoachSidecar = nil
            }
        }
    }

    func shutdownSidecar() {
        liveCoachSidecar?.shutdown()
        liveCoachSidecar = nil
    }

    /// Wipes the entire coach conversation history + working memory.
    /// Starts the sidecar if needed, issues a DELETE, then shuts it back down
    /// if no meeting is active.
    func resetCoachMemory() {
        Task {
            let sidecar: LiveCoachSidecar
            let startedJustForThis: Bool
            if let existing = liveCoachSidecar, existing.isRunning {
                sidecar = existing
                startedJustForThis = false
            } else {
                let fresh = LiveCoachSidecar()
                do {
                    try await fresh.launch()
                } catch {
                    fputs("[muesli-native] resetCoachMemory: failed to launch sidecar: \(error)\n", stderr)
                    return
                }
                sidecar = fresh
                startedJustForThis = true
            }
            let client = LiveCoachClient(sidecar: sidecar)
            do {
                try await client.deleteResource(id: "user-muesli")
                fputs("[muesli-native] coach memory reset\n", stderr)
            } catch {
                fputs("[muesli-native] resetCoachMemory failed: \(error)\n", stderr)
            }
            if startedJustForThis {
                sidecar.shutdown()
            }
        }
    }

    // MARK: - Panel

    @objc func toggleLiveTranscript() {
        guard isMeetingActive() else { return }
        if liveTranscriptController == nil {
            liveTranscriptController = LiveTranscriptPanelController()
        }
        liveTranscriptController?.toggle(
            source: self,
            title: activeMeetingTitle,
            meetingID: activeMeetingID,
            config: configProvider(),
            coachSidecar: liveCoachSidecar
        )
        statusBarController?.refresh()
    }

    var isLiveTranscriptVisible: Bool {
        liveTranscriptController?.isVisible ?? false
    }

    // MARK: - Chunk accumulator (called from MeetingSession.onChunkResolved)

    private func handleChunkResolved(_ resolution: MeetingChunkResolution) {
        if !resolution.mic.isEmpty {
            resolvedMicSegments.withLock { $0.append(contentsOf: resolution.mic) }
        }
        if !resolution.system.isEmpty {
            resolvedSystemSegments.withLock { $0.append(contentsOf: resolution.system) }
        }
        if !resolution.diarization.isEmpty {
            resolvedDiarizationSegments.withLock { $0.append(contentsOf: resolution.diarization) }

            // Register new speaker IDs in the stable label map.
            for seg in resolution.diarization {
                speakerLabelMap.withLock { map in
                    if map[seg.speakerId] == nil {
                        let num = self.nextSpeakerNumber.withLock { n in
                            let current = n
                            n += 1
                            return current
                        }
                        map[seg.speakerId] = "Speaker \(num)"
                    }
                }
            }
        }
    }

    private func resetAccumulator() {
        resolvedMicSegments.withLock { $0.removeAll() }
        resolvedSystemSegments.withLock { $0.removeAll() }
        resolvedDiarizationSegments.withLock { $0.removeAll() }
        speakerLabelMap.withLock { $0.removeAll() }
        nextSpeakerNumber.withLock { $0 = 1 }
        lastMicOffset = 0
        lastSystemOffset = 0
    }

    // MARK: - LiveTranscriptSource

    func segmentCounts() -> (mic: Int, system: Int) {
        (resolvedMicSegments.withLock { $0.count },
         resolvedSystemSegments.withLock { $0.count })
    }

    func allSegments() -> (mic: [SpeechSegment], system: [SpeechSegment], diarization: [TimedSpeakerSegment], labelMap: [String: String]) {
        (resolvedMicSegments.withLock { Array($0) },
         resolvedSystemSegments.withLock { Array($0) },
         resolvedDiarizationSegments.withLock { Array($0) },
         speakerLabelMap.withLock { $0 })
    }

    func transcriptDelta(
        micOffset: Int,
        systemOffset: Int
    ) -> (text: String, newMicOffset: Int, newSystemOffset: Int) {
        let meetingStart = meetingStartTime ?? Date()

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

    // MARK: - Transcript clipboard hotkey (Cmd+Shift+C/T during meetings)

    private func installTranscriptHotkey() {
        lastMicOffset = 0
        lastSystemOffset = 0

        transcriptKeyMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            _ = self?.handleTranscriptHotkey(event)
        }
        transcriptKeyMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleTranscriptHotkey(event) == true {
                return nil // consume the event
            }
            return event
        }
    }

    private func removeTranscriptHotkey() {
        if let monitor = transcriptKeyMonitorGlobal {
            NSEvent.removeMonitor(monitor)
            transcriptKeyMonitorGlobal = nil
        }
        if let monitor = transcriptKeyMonitorLocal {
            NSEvent.removeMonitor(monitor)
            transcriptKeyMonitorLocal = nil
        }
    }

    @discardableResult
    private func handleTranscriptHotkey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains([.command, .shift]),
              isMeetingActive() else {
            return false
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            copyTranscriptDeltaToClipboard()
            return true
        case "t":
            toggleLiveTranscript()
            return true
        default:
            return false
        }
    }

    private func copyTranscriptDeltaToClipboard() {
        let (text, newMicOffset, newSystemOffset) = transcriptDelta(
            micOffset: lastMicOffset,
            systemOffset: lastSystemOffset
        )

        guard !text.isEmpty else {
            indicator?.showWarning("No new transcript", icon: "📋")
            return
        }

        lastMicOffset = newMicOffset
        lastSystemOffset = newSystemOffset

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        indicator?.showWarning("Copied to clipboard", icon: "✅")
        fputs("[meeting] transcript delta copied to clipboard (\(text.count) chars)\n", stderr)
    }
}
