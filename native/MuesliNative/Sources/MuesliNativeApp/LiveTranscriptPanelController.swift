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

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(session: MeetingSession, title: String) {
        meetingSession = session
        lastMicCount = 0
        lastSystemCount = 0
        viewModel.entries = []
        viewModel.meetingTitle = title

        if panel == nil {
            buildPanel()
        }
        panel?.makeKeyAndOrderFront(nil)
        startPolling()
        // Run an immediate poll so the panel isn't empty if segments already exist
        poll()
    }

    func hide() {
        stopPolling()
        panel?.orderOut(nil)
    }

    func toggle(session: MeetingSession, title: String) {
        if isVisible {
            hide()
        } else {
            show(session: session, title: title)
        }
    }

    // MARK: - Panel construction

    private func buildPanel() {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let panelWidth: CGFloat = 380
        let panelHeight: CGFloat = 500
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
        panel.minSize = NSSize(width: 280, height: 200)

        let rootView = LiveTranscriptView(viewModel: viewModel) { [weak self] in
            self?.hide()
        }
        panel.contentView = NSHostingView(rootView: rootView)

        self.panel = panel
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        // Use a Timer directly on the main run loop (no Task wrapper needed since
        // the class is @MainActor and the timer fires on the main thread).
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

        // Parse "[HH:mm:ss] Speaker: text" lines into stable entries
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
    }
}
