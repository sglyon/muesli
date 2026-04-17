import SwiftUI

struct LiveCoachView: View {
    @ObservedObject var viewModel: LiveCoachViewModel
    var onSend: (String) -> Void

    @State private var draft: String = ""
    @FocusState private var chatFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().background(MuesliTheme.surfaceBorder)
            if let placeholder = viewModel.placeholderMessage {
                placeholderView(placeholder)
            } else {
                messageList
            }
            Divider().background(MuesliTheme.surfaceBorder)
            chatInput
        }
        .background(MuesliTheme.backgroundBase)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Image(systemName: "sparkles")
                .foregroundStyle(MuesliTheme.accent)
            Text("Coach")
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
            Spacer()
            if viewModel.isStreaming {
                Text("thinking…")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
        }
        .padding(.horizontal, MuesliTheme.spacing12)
        .padding(.vertical, MuesliTheme.spacing8)
        .background(MuesliTheme.backgroundRaised)
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    if viewModel.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(viewModel.messages) { msg in
                            messageRow(msg)
                                .id(msg.id)
                        }
                    }
                    if let err = viewModel.errorText {
                        Text(err)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(Color.red.opacity(0.9))
                            .padding(.top, MuesliTheme.spacing4)
                    }
                }
                .padding(MuesliTheme.spacing12)
            }
            .onChange(of: viewModel.messages) { _, newMessages in
                if let last = newMessages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: "message")
                .font(.system(size: 24))
                .foregroundStyle(MuesliTheme.textTertiary)
            Text("Waiting for transcript…")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textTertiary)
            Text("Coach will start commenting once you've spoken for a bit, or ask a question below.")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func messageRow(_ msg: CoachMessage) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
            HStack(spacing: MuesliTheme.spacing8) {
                badge(for: msg.kind)
                Text(timeFormatter.string(from: msg.timestamp))
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .monospacedDigit()
            }
            Text(msg.text + (msg.isStreaming ? "▋" : ""))
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(MuesliTheme.spacing8)
        .background(background(for: msg.kind))
        .cornerRadius(6)
    }

    private func badge(for kind: CoachMessage.Kind) -> some View {
        let (label, color): (String, Color) = {
            switch kind {
            case .proactiveAssistant: return ("Coach", MuesliTheme.accent)
            case .userChat: return ("You", MuesliTheme.textSecondary)
            case .assistantReply: return ("Coach", MuesliTheme.accent)
            case .systemNotice: return ("System", MuesliTheme.textTertiary)
            }
        }()
        return Text(label)
            .font(MuesliTheme.captionMedium())
            .foregroundStyle(color)
    }

    private func background(for kind: CoachMessage.Kind) -> Color {
        switch kind {
        case .userChat: return MuesliTheme.backgroundRaised
        case .systemNotice: return MuesliTheme.backgroundRaised.opacity(0.6)
        default: return Color.clear
        }
    }

    private func placeholderView(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(MuesliTheme.spacing12)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Chat input

    private var chatInput: some View {
        HStack(alignment: .bottom, spacing: MuesliTheme.spacing8) {
            TextEditor(text: $draft)
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .background(MuesliTheme.backgroundRaised)
                .cornerRadius(6)
                .frame(minHeight: 32, maxHeight: 96)
                .focused($chatFieldFocused)
                .disabled(viewModel.placeholderMessage != nil)

            Button {
                submit()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(
                        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? MuesliTheme.textTertiary
                            : MuesliTheme.accent
                    )
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isStreaming || viewModel.placeholderMessage != nil)
        }
        .padding(.horizontal, MuesliTheme.spacing12)
        .padding(.vertical, MuesliTheme.spacing8)
    }

    private func submit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend(trimmed)
        draft = ""
    }

    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }
}
