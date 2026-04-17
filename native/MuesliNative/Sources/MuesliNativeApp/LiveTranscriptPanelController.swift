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

        if config.liveCoach.enabled, let sidecar = coachSidecar, sidecar.isRunning {
            let client = LiveCoachClient(sidecar: sidecar)
            let engine = LiveCoachEngine(
                client: client,
                session: session,
                settings: config.liveCoach,
                config: config,
                resourceId: "user-muesli",
                threadId: currentThreadId!
            )
            self.coachEngine = engine
            Task { await engine.bootstrap() }
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

    // MARK: - Panel construction

    private func buildPanel() {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let hasCoach = coachEngine != nil
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

        let rootView = LiveTranscriptView(
            viewModel: viewModel,
            coachViewModel: coachEngine?.viewModel,
            onClose: { [weak self] in self?.hide() },
            onSendCoachMessage: { [weak self] text in self?.coachEngine?.sendUserMessage(text) }
        )
        panel.contentView = NSHostingView(rootView: rootView)

        self.panel = panel
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

        coachEngine?.onTranscriptTick()
    }
}
