import Foundation
import SwiftUI
import MuesliCore

// MARK: - View model

struct CoachMessage: Identifiable, Equatable {
    enum Kind: Equatable {
        case proactiveAssistant
        case userChat
        case assistantReply
        case systemNotice
    }
    let id: UUID
    var kind: Kind
    let timestamp: Date
    var text: String
    var isStreaming: Bool

    init(kind: Kind, text: String, timestamp: Date = Date(), isStreaming: Bool = false) {
        self.id = UUID()
        self.kind = kind
        self.timestamp = timestamp
        self.text = text
        self.isStreaming = isStreaming
    }
}

@MainActor
final class LiveCoachViewModel: ObservableObject {
    @Published var messages: [CoachMessage] = []
    @Published var isStreaming: Bool = false
    @Published var errorText: String?
    @Published var isEnabled: Bool = true
    @Published var placeholderMessage: String?
}

// MARK: - XML wrapping helpers

enum CoachXML {
    /// Escape a transcript fragment so it's safe to wrap in XML tags.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            default: out.append(ch)
            }
        }
        return out
    }

    static func timeAttribute(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.toNearestOrEven))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    static func wrapTranscript(_ body: String, since: Double, until: Double) -> String {
        """
        <transcript_update since="\(timeAttribute(since))" until="\(timeAttribute(until))">
        \(escape(body))
        </transcript_update>
        """
    }

    static func wrapUser(_ text: String) -> String {
        "<user_message>\(escape(text))</user_message>"
    }

    /// Combine an optional transcript delta with a user question into one turn.
    static func wrapUserWithTranscript(user: String, transcript: String?, since: Double, until: Double) -> String {
        guard let transcript, !transcript.isEmpty else { return wrapUser(user) }
        return wrapTranscript(transcript, since: since, until: until) + "\n\n" + wrapUser(user)
    }
}

// MARK: - Engine

/// Orchestrates coach turns: watches the meeting transcript, debounces proactive
/// triggers, sends turns to the sidecar over SSE, and streams deltas into the
/// view model.
@MainActor
final class LiveCoachEngine {
    let viewModel = LiveCoachViewModel()

    private let client: LiveCoachClient
    private weak var session: MeetingSession?
    private var settings: LiveCoachSettings
    private let config: AppConfig
    private let resourceId: String
    private let threadId: String

    // Transcript tracking
    private var lastMicOffset: Int = 0
    private var lastSystemOffset: Int = 0
    private var lastTurnAtSeconds: Double = 0
    private var pendingDeltaChars: Int = 0

    // In-flight turn guard
    private var inFlight: Bool = false

    init(
        client: LiveCoachClient,
        session: MeetingSession,
        settings: LiveCoachSettings,
        config: AppConfig,
        resourceId: String,
        threadId: String
    ) {
        self.client = client
        self.session = session
        self.settings = settings
        self.config = config
        self.resourceId = resourceId
        self.threadId = threadId
    }

    var preserveThreadPreference: Bool { settings.preserveThreadAcrossMeetings }

    // MARK: - Public API

    /// Hydrate view model from prior thread history (if any) and render a
    /// placeholder when misconfigured.
    func bootstrap() async {
        if !settings.enabled {
            viewModel.placeholderMessage = "Live Coach is disabled. Turn it on in Settings."
            return
        }
        if !credentialsPresent(for: settings.provider) {
            viewModel.placeholderMessage = "Configure Live Coach credentials in Settings."
            return
        }
        do {
            let history = try await client.fetchThread(id: threadId)
            let hydrated = history.messages.compactMap { msg -> CoachMessage? in
                guard !msg.content.isEmpty else { return nil }
                switch msg.role {
                case "user":
                    // User messages on the wire are XML-wrapped; strip the outer tags
                    // so we only show the inner prose in the UI.
                    let display = extractHumanPrompt(msg.content)
                    return CoachMessage(kind: .userChat, text: display, timestamp: parseISO(msg.createdAt))
                case "assistant":
                    return CoachMessage(kind: .assistantReply, text: msg.content, timestamp: parseISO(msg.createdAt))
                default:
                    return nil
                }
            }
            viewModel.messages = hydrated
        } catch {
            fputs("[live-coach] thread hydration failed: \(error)\n", stderr)
        }
    }

    /// Called every transcript poll from the panel. Computes any new transcript
    /// delta and fires a proactive turn if thresholds are met.
    func onTranscriptTick() {
        guard settings.enabled, settings.proactiveEnabled, !inFlight else { return }
        guard let session else { return }
        guard credentialsPresent(for: settings.provider) else { return }

        let (delta, newMicOffset, newSystemOffset, untilSeconds) = extractDelta(from: session)
        if delta.isEmpty {
            return
        }
        pendingDeltaChars += delta.count
        if pendingDeltaChars < settings.minCharsBeforeTrigger {
            return
        }

        // Commit the new offsets BEFORE firing so a retry doesn't replay the
        // same transcript. If the turn fails we still advance — the assistant
        // just misses that chunk, which is acceptable.
        lastMicOffset = newMicOffset
        lastSystemOffset = newSystemOffset
        let since = lastTurnAtSeconds
        lastTurnAtSeconds = untilSeconds
        pendingDeltaChars = 0

        let wrapped = CoachXML.wrapTranscript(delta, since: since, until: untilSeconds)
        Task { await self.runTurn(content: wrapped, kind: .transcriptUpdate, displayUser: nil) }
    }

    /// Called when the user types a question in the chat input.
    func sendUserMessage(_ text: String) {
        guard settings.enabled, !inFlight else { return }
        guard let session else { return }
        guard credentialsPresent(for: settings.provider) else {
            viewModel.errorText = "Live coach is not configured — check Settings."
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Include any fresh transcript delta in the same user turn so the
        // coach has up-to-the-moment context.
        let (delta, newMicOffset, newSystemOffset, untilSeconds) = extractDelta(from: session)
        let since = lastTurnAtSeconds
        lastMicOffset = newMicOffset
        lastSystemOffset = newSystemOffset
        lastTurnAtSeconds = untilSeconds
        pendingDeltaChars = 0

        let wrapped = CoachXML.wrapUserWithTranscript(user: trimmed, transcript: delta.isEmpty ? nil : delta, since: since, until: untilSeconds)
        Task { await self.runTurn(content: wrapped, kind: .userMessage, displayUser: trimmed) }
    }

    func shutdown(preserveThread: Bool) async {
        if !preserveThread {
            try? await client.deleteThread(id: threadId)
        }
    }

    // MARK: - Turn execution

    private func runTurn(content: String, kind: CoachTurnRequest.Turn.Kind, displayUser: String?) async {
        inFlight = true
        viewModel.isStreaming = true
        defer {
            inFlight = false
            viewModel.isStreaming = false
        }

        if let displayUser {
            viewModel.messages.append(CoachMessage(kind: .userChat, text: displayUser))
        }

        // Seed an assistant-reply bubble that we mutate as deltas arrive.
        let replyKind: CoachMessage.Kind = (kind == .transcriptUpdate) ? .proactiveAssistant : .assistantReply
        viewModel.messages.append(CoachMessage(kind: replyKind, text: "", isStreaming: true))
        let streamingIndex = viewModel.messages.count - 1

        let request = await buildRequest(content: content, kind: kind)

        do {
            for try await event in client.streamTurn(request) {
                switch event {
                case .delta(let chunk):
                    viewModel.messages[streamingIndex].text += chunk
                case .usage:
                    break
                case .done:
                    viewModel.messages[streamingIndex].isStreaming = false
                case .error(let message):
                    viewModel.errorText = message
                    viewModel.messages[streamingIndex].isStreaming = false
                    viewModel.messages[streamingIndex].text += "\n\n[error: \(message)]"
                }
            }
        } catch {
            viewModel.errorText = error.localizedDescription
            viewModel.messages[streamingIndex].isStreaming = false
            if viewModel.messages[streamingIndex].text.isEmpty {
                viewModel.messages[streamingIndex].text = "[error: \(error.localizedDescription)]"
            }
        }
    }

    private func buildRequest(content: String, kind: CoachTurnRequest.Turn.Kind) async -> CoachTurnRequest {
        let creds = await makeCredentials()
        return CoachTurnRequest(
            threadId: threadId,
            resourceId: resourceId,
            provider: settings.provider,
            model: settings.activeModel.isEmpty ? defaultModel(for: settings.provider) : settings.activeModel,
            credentials: creds,
            systemPrompt: settings.systemPrompt,
            agentInstructions: settings.agentInstructions.isEmpty ? nil : settings.agentInstructions,
            turn: CoachTurnRequest.Turn(kind: kind, content: content)
        )
    }

    private func makeCredentials() async -> CoachTurnRequest.Credentials {
        var creds = CoachTurnRequest.Credentials()
        switch settings.provider {
        case "anthropic":
            creds.apiKey = settings.anthropicAPIKey
        case "openai":
            creds.apiKey = config.openAIAPIKey
        case "chatgpt":
            if let (token, accountId) = try? await ChatGPTAuthManager.shared.validAccessToken() {
                creds.bearer = token
                creds.accountId = accountId
            }
        default:
            break
        }
        if settings.enableSemanticRecall, !config.openAIAPIKey.isEmpty {
            creds.embedderAPIKey = config.openAIAPIKey
        }
        return creds
    }

    private func credentialsPresent(for provider: String) -> Bool {
        switch provider {
        case "anthropic": return !settings.anthropicAPIKey.isEmpty
        case "openai": return !config.openAIAPIKey.isEmpty
        case "chatgpt": return ChatGPTAuthManager.shared.isAuthenticated
        default: return false
        }
    }

    private func defaultModel(for provider: String) -> String {
        switch provider {
        case "anthropic": return "claude-sonnet-4-6"
        case "openai": return "gpt-5.4-mini"
        case "chatgpt": return "gpt-5.4-mini"
        default: return ""
        }
    }

    // MARK: - Transcript delta

    private func extractDelta(from session: MeetingSession) -> (text: String, newMicOffset: Int, newSystemOffset: Int, until: Double) {
        let meetingStart = session.startTime ?? Date()
        let snapshot = session.allSegments()

        let micSegs = Array(snapshot.mic.dropFirst(lastMicOffset))
        let sysSegs = Array(snapshot.system.dropFirst(lastSystemOffset))
        let newMicOffset = lastMicOffset + micSegs.count
        let newSystemOffset = lastSystemOffset + sysSegs.count

        var until = lastTurnAtSeconds
        for seg in micSegs { until = max(until, Double(seg.end)) }
        for seg in sysSegs { until = max(until, Double(seg.end)) }

        guard !micSegs.isEmpty || !sysSegs.isEmpty else {
            return ("", newMicOffset, newSystemOffset, until)
        }

        let formatted = TranscriptFormatter.merge(
            micSegments: micSegs,
            systemSegments: sysSegs,
            diarizationSegments: snapshot.diarization.isEmpty ? nil : snapshot.diarization,
            speakerLabelMap: snapshot.labelMap.isEmpty ? nil : snapshot.labelMap,
            meetingStart: meetingStart
        )
        return (formatted, newMicOffset, newSystemOffset, until)
    }

    private func extractHumanPrompt(_ raw: String) -> String {
        // Strip outer <user_message>...</user_message> if present; collapse
        // leading <transcript_update>...</transcript_update> blocks so the UI
        // shows only the human prose.
        var text = raw
        if let range = text.range(of: "<user_message>") {
            text = String(text[range.upperBound...])
        }
        if let range = text.range(of: "</user_message>") {
            text = String(text[..<range.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseISO(_ s: String?) -> Date {
        guard let s else { return Date() }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.date(from: s) ?? ISO8601DateFormatter().date(from: s) ?? Date()
    }
}
