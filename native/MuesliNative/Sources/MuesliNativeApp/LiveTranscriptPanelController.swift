import AppKit
import SwiftUI
import MuesliCore

@MainActor
final class LiveTranscriptPanelController {
    private var panel: NSPanel?
    private var pollTimer: Timer?
    private let viewModel = LiveTranscriptViewModel()
    private weak var meetingSession: MeetingSession?
    private var lastMicCount = 0
    private var lastSystemCount = 0

    // Live Coach plumbing (present only when enabled in settings).
    private var coachEngine: LiveCoachEngine?
    private weak var coachSidecar: LiveCoachSidecar?
    private var currentThreadId: String?
    private var currentConfig: AppConfig?
    /// Active profile id for THIS panel session — independent of the global
    /// default in settings, so swapping profiles mid-meeting doesn't change
    /// the user's preferred default for new meetings.
    private var sessionActiveProfileID: UUID?
    /// Placeholder view-model shown while the sidecar finishes its handshake.
    /// Once `coachEngine` exists, its own viewModel takes over.
    private var pendingCoachViewModel: LiveCoachViewModel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(
        session: MeetingSession,
        title: String,
        meetingID: String,
        config: AppConfig,
        coachSidecar: LiveCoachSidecar?
    ) {
        meetingSession = session
        lastMicCount = 0
        lastSystemCount = 0
        viewModel.entries = []
        viewModel.meetingTitle = title

        self.coachSidecar = coachSidecar
        currentThreadId = "meeting-\(meetingID)"
        currentConfig = config
        sessionActiveProfileID = config.liveCoach.activeProfileID
        pendingCoachViewModel = nil

        if config.liveCoach.enabled {
            if let sidecar = coachSidecar, sidecar.isReady {
                instantiateCoachEngine(profile: config.liveCoach.activeProfile)
            } else {
                // Show the coach column immediately with a "starting..." state so
                // the user knows the column exists; instantiate the real engine
                // once the sidecar finishes its handshake.
                let placeholder = LiveCoachViewModel()
                placeholder.placeholderMessage = coachSidecar == nil
                    ? "Live Coach binary missing — see logs."
                    : "Coach starting…"
                pendingCoachViewModel = placeholder
                self.coachEngine = nil
                Task { [weak self] in await self?.upgradeToLiveEngineWhenReady() }
            }
        } else {
            self.coachEngine = nil
        }

        if panel == nil {
            buildPanel()
        }
        panel?.makeKeyAndOrderFront(nil)
        startPolling()
        poll()
    }

    func hide() {
        stopPolling()
        panel?.orderOut(nil)
        if let engine = coachEngine, let threadId = currentThreadId, let coachSidecar {
            // If the user opted out of cross-meeting memory, delete the thread on close.
            let preserve = engine.preserveThreadPreference
            if !preserve, coachSidecar.isRunning {
                Task { try? await LiveCoachClient(sidecar: coachSidecar).deleteThread(id: threadId) }
            }
        }
        coachEngine = nil
        currentThreadId = nil
    }

    func toggle(
        session: MeetingSession,
        title: String,
        meetingID: String,
        config: AppConfig,
        coachSidecar: LiveCoachSidecar?
    ) {
        if isVisible {
            hide()
        } else {
            show(session: session, title: title, meetingID: meetingID, config: config, coachSidecar: coachSidecar)
        }
    }

    private func instantiateCoachEngine(profile: CoachProfile) {
        guard let sidecar = coachSidecar, let threadId = currentThreadId, let config = currentConfig else { return }
        let client = LiveCoachClient(sidecar: sidecar)
        let engine = LiveCoachEngine(
            client: client,
            settings: config.liveCoach,
            profile: profile,
            config: config,
            threadId: threadId
        )
        self.coachEngine = engine
        self.pendingCoachViewModel = nil
        sessionActiveProfileID = profile.id
        Task { await engine.bootstrap() }
    }

    /// Called when the user picks a different profile in the panel header.
    /// Swaps the engine for one bound to the new profile and rehydrates from
    /// that profile's prior thread (likely empty for a never-used combo).
    private func switchToProfile(id: UUID) {
        guard let config = currentConfig else { return }
        guard let next = config.liveCoach.profiles.first(where: { $0.id == id }) else { return }
        if let current = coachEngine?.activeProfile, current.id == next.id { return }
        instantiateCoachEngine(profile: next)
    }

    /// Polls the sidecar's handshake state, and when ready swaps the
    /// placeholder out for a real engine + refreshes the panel.
    private func upgradeToLiveEngineWhenReady() async {
        guard let sidecar = coachSidecar, let config = currentConfig else { return }
        let ready = await sidecar.waitUntilReady(timeout: 30.0)
        guard ready else {
            pendingCoachViewModel?.placeholderMessage =
                "Coach unavailable — sidecar didn't start. Check Console for [live-coach] errors."
            return
        }
        // Race guard: panel may have been closed while we were waiting.
        guard panel?.isVisible == true, currentConfig != nil else { return }
        instantiateCoachEngine(profile: config.liveCoach.activeProfile)
        refreshPanelContent()
    }

    private func refreshPanelContent() {
        guard let panel else { return }
        panel.contentView = NSHostingView(rootView: makeRootView())
    }

    // MARK: - Panel construction

    /// True when the panel should render the coach column (either a live
    /// engine or a placeholder waiting for the sidecar handshake).
    private var hasCoachColumn: Bool {
        coachEngine != nil || pendingCoachViewModel != nil
    }

    private func currentCoachViewModel() -> LiveCoachViewModel? {
        coachEngine?.viewModel ?? pendingCoachViewModel
    }

    private func buildPanel() {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let hasCoach = hasCoachColumn
        let panelWidth: CGFloat = hasCoach ? 900 : 380
        let panelHeight: CGFloat = hasCoach ? 600 : 500
        let margin: CGFloat = 20
        let x = screen.visibleFrame.maxX - panelWidth - margin
        let y = screen.visibleFrame.midY - panelHeight / 2

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: panelWidth, height: panelHeight),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = NSColor(red: 0.086, green: 0.090, blue: 0.098, alpha: 0.95)
        panel.minSize = NSSize(width: hasCoach ? 640 : 280, height: hasCoach ? 420 : 200)

        panel.contentView = NSHostingView(rootView: makeRootView())

        self.panel = panel
    }

    private func makeRootView() -> LiveTranscriptView {
        LiveTranscriptView(
            viewModel: viewModel,
            coachViewModel: currentCoachViewModel(),
            availableProfiles: currentConfig?.liveCoach.profiles ?? [],
            activeProfileID: sessionActiveProfileID,
            onClose: { [weak self] in self?.hide() },
            onSendCoachMessage: { [weak self] text in self?.coachEngine?.sendUserMessage(text) },
            onSelectProfile: { [weak self] id in
                self?.switchToProfile(id: id)
                self?.refreshPanelContent()
            }
        )
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        guard let session = meetingSession else {
            fputs("[muesli-native] live transcript: session is nil, stopping poll\n", stderr)
            stopPolling()
            return
        }

        let counts = session.segmentCounts()
        guard counts.mic != lastMicCount || counts.system != lastSystemCount else { return }

        fputs("[muesli-native] live transcript: mic=\(counts.mic) sys=\(counts.system) (was mic=\(lastMicCount) sys=\(lastSystemCount))\n", stderr)
        lastMicCount = counts.mic
        lastSystemCount = counts.system

        let (micSegs, sysSegs, diarSegs, labelMap) = session.allSegments()
        let meetingStart = session.startTime ?? Date()

        let merged = TranscriptFormatter.merge(
            micSegments: micSegs,
            systemSegments: sysSegs,
            diarizationSegments: diarSegs.isEmpty ? nil : diarSegs,
            speakerLabelMap: labelMap.isEmpty ? nil : labelMap,
            meetingStart: meetingStart
        )

        let lines = merged.components(separatedBy: "\n")
        var entries: [TranscriptEntry] = []
        for (index, line) in lines.enumerated() where !line.isEmpty {
            guard line.hasPrefix("["),
                  let closeBracket = line.firstIndex(of: "]"),
                  line.distance(from: closeBracket, to: line.endIndex) > 2 else { continue }
            let timestamp = String(line[line.index(after: line.startIndex)..<closeBracket])
            let rest = line[line.index(closeBracket, offsetBy: 2)...]
            guard let colonRange = rest.range(of: ": ") else { continue }
            let speaker = String(rest[rest.startIndex..<colonRange.lowerBound])
            let text = String(rest[colonRange.upperBound...])
            entries.append(TranscriptEntry(id: index, timestamp: timestamp, speaker: speaker, text: text))
        }
        viewModel.entries = entries

        if let engine = coachEngine {
            let snapshot = CoachTranscriptSnapshot(
                mic: micSegs,
                system: sysSegs,
                diarization: diarSegs,
                labelMap: labelMap,
                meetingStart: meetingStart
            )
            engine.onTranscriptTick(snapshot: snapshot)
        }
    }
}
