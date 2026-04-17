import SwiftUI

struct TranscriptEntry: Identifiable, Equatable {
    let id: Int
    let timestamp: String
    let speaker: String
    let text: String
}

@MainActor
final class LiveTranscriptViewModel: ObservableObject {
    @Published var entries: [TranscriptEntry] = []
    @Published var meetingTitle: String = ""
}

struct LiveTranscriptView: View {
    @ObservedObject var viewModel: LiveTranscriptViewModel
    var coachViewModel: LiveCoachViewModel?
    var availableProfiles: [CoachProfile] = []
    var activeProfileID: UUID? = nil
    var onClose: (() -> Void)?
    var onSendCoachMessage: ((String) -> Void)?
    var onSelectProfile: ((UUID) -> Void)? = nil

    var body: some View {
        Group {
            if let coachViewModel {
                HSplitView {
                    transcriptColumn
                        .frame(minWidth: 280, idealWidth: 420)
                    LiveCoachView(
                        viewModel: coachViewModel,
                        availableProfiles: availableProfiles,
                        activeProfileID: activeProfileID,
                        onSend: { text in onSendCoachMessage?(text) },
                        onSelectProfile: onSelectProfile
                    )
                    .frame(minWidth: 320, idealWidth: 480)
                }
            } else {
                transcriptColumn
            }
        }
        .background(MuesliTheme.backgroundBase)
    }

    private var transcriptColumn: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().background(MuesliTheme.surfaceBorder)
            transcriptList
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Image(systemName: "waveform")
                .foregroundStyle(MuesliTheme.recording)
            Text(viewModel.meetingTitle)
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
                .lineLimit(1)
            Spacer()
            Text("\u{2318}\u{21E7}T")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
            Button(action: { onClose?() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, MuesliTheme.spacing12)
        .padding(.vertical, MuesliTheme.spacing8)
        .background(MuesliTheme.backgroundRaised)
    }

    // MARK: - Transcript list

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    if viewModel.entries.isEmpty {
                        emptyState
                    } else {
                        ForEach(viewModel.entries) { entry in
                            transcriptRow(entry)
                        }
                    }
                }
                .padding(MuesliTheme.spacing12)
            }
            .onChange(of: viewModel.entries) { _, newEntries in
                if let last = newEntries.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 24))
                .foregroundStyle(MuesliTheme.textTertiary)
            Text("Waiting for speech...")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Row

    private func transcriptRow(_ entry: TranscriptEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MuesliTheme.spacing8) {
            Text(entry.timestamp)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
                .monospacedDigit()
            Text(entry.speaker)
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(entry.speaker == "You" ? MuesliTheme.accent : MuesliTheme.textSecondary)
                .frame(width: 52, alignment: .leading)
            Text(entry.text)
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
                .textSelection(.enabled)
        }
    }
}
