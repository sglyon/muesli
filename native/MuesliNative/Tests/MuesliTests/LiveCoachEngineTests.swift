import Testing
import Foundation
import FluidAudio
@testable import MuesliNativeApp
@testable import MuesliCore

// MARK: - Mock client

/// Records every coach turn and replays scripted SSE events so engine tests
/// don't need a sidecar process.
@MainActor
final class MockCoachClient: CoachClientProtocol {
    struct Recorded {
        let request: CoachTurnRequest
    }

    var recordedTurns: [Recorded] = []
    var recordedDeleteThreads: [String] = []
    var recordedDeleteResources: [String] = []

    /// Pre-loaded history returned by `fetchThread`.
    var fetchThreadHistory: ThreadHistoryResponse?
    /// Each invocation of `streamTurn` consumes the next script. If empty, we
    /// emit a default ".delta(\"ok\"), .done" stream.
    var scriptedStreams: [[CoachStreamEvent]] = []
    /// Optional per-turn hold — when set, streamTurn awaits this continuation
    /// before emitting events. Lets a test deterministically keep a stream
    /// open while it triggers more ticks.
    var holdNextTurn: AsyncStream<Void>.Continuation?
    var holdStream: AsyncStream<Void>?

    func fetchThread(id: String) async throws -> ThreadHistoryResponse {
        if let history = fetchThreadHistory {
            return history
        }
        return ThreadHistoryResponse(threadId: id, messages: [])
    }

    func deleteThread(id: String) async throws {
        recordedDeleteThreads.append(id)
    }

    func deleteResource(id: String) async throws {
        recordedDeleteResources.append(id)
    }

    func streamTurn(_ request: CoachTurnRequest) -> AsyncThrowingStream<CoachStreamEvent, Error> {
        recordedTurns.append(Recorded(request: request))
        let events: [CoachStreamEvent] = scriptedStreams.isEmpty
            ? [.delta("ok"), .done]
            : scriptedStreams.removeFirst()
        let hold = holdStream
        holdStream = nil
        holdNextTurn = nil
        return AsyncThrowingStream { continuation in
            Task {
                if let hold {
                    for await _ in hold { break }
                }
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    /// Convenience: arrange for the next streamTurn to block until released.
    func holdNext() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        holdStream = stream
        holdNextTurn = continuation
    }

    func release() {
        holdNextTurn?.yield(())
        holdNextTurn?.finish()
    }
}

// MARK: - Helpers

@MainActor
private func makeEngine(
    client: MockCoachClient,
    settings: LiveCoachSettings = .testDefault(),
    profile: CoachProfile? = nil,
    config: AppConfig? = nil,
    threadId: String = "test-thread"
) -> LiveCoachEngine {
    var resolved = config ?? AppConfig()
    if config == nil {
        // Default tests don't care about the embedder key — use a sentinel so
        // engine code that consults it doesn't trip on an empty value.
        resolved.openAIAPIKey = "test-openai-key"
    }
    let resolvedProfile = profile ?? settings.activeProfile
    return LiveCoachEngine(
        client: client,
        settings: settings,
        profile: resolvedProfile,
        config: resolved,
        threadId: threadId
    )
}

/// Mutates the active profile in-place so each test can tweak just the
/// profile fields it cares about without rebuilding the whole settings.
private func withProfile(_ settings: inout LiveCoachSettings, _ mutate: (inout CoachProfile) -> Void) {
    if let idx = settings.profiles.firstIndex(where: { $0.id == settings.activeProfileID }) {
        mutate(&settings.profiles[idx])
    }
}

private extension LiveCoachSettings {
    static func testDefault() -> LiveCoachSettings {
        var s = LiveCoachSettings()
        s.enabled = true
        s.anthropicAPIKey = "ant-test-key"
        // Replace the seeded defaults with a single test-friendly profile.
        let p = CoachProfile(
            id: CoachProfile.salesCoachID,
            name: "Test Coach",
            provider: "anthropic",
            anthropicModel: "claude-sonnet-4-6",
            openAIModel: "gpt-5.4-mini",
            chatGPTModel: "gpt-5.4-mini",
            systemPrompt: "You are a helpful coach.",
            agentInstructions: "",
            workingMemoryTemplate: "# Test profile working memory",
            proactiveEnabled: true,
            minCharsBeforeTrigger: 50
        )
        s.profiles = [p]
        s.activeProfileID = p.id
        return s
    }
}

private func snapshot(
    mic: [SpeechSegment] = [],
    system: [SpeechSegment] = [],
    diarization: [TimedSpeakerSegment] = [],
    meetingStart: Date = Date(timeIntervalSince1970: 0)
) -> CoachTranscriptSnapshot {
    CoachTranscriptSnapshot(
        mic: mic,
        system: system,
        diarization: diarization,
        labelMap: [:],
        meetingStart: meetingStart
    )
}

private func micSeg(_ text: String, start: Float = 0, end: Float = 1) -> SpeechSegment {
    SpeechSegment(start: TimeInterval(start), end: TimeInterval(end), text: text)
}

/// Pump the main run loop until `condition` returns true or `timeout` elapses.
@MainActor
private func waitUntil(
    timeout: TimeInterval = 1.0,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

// MARK: - Suites

@Suite("Live Coach XML wrapping")
struct LiveCoachXMLTests {

    @Test("time attribute formats seconds as HH:MM:SS")
    func timeAttribute() {
        #expect(CoachXML.timeAttribute(0) == "00:00:00")
        #expect(CoachXML.timeAttribute(61) == "00:01:01")
        #expect(CoachXML.timeAttribute(3725) == "01:02:05")
    }

    @Test("escape protects XML-sensitive characters")
    func escape() {
        #expect(CoachXML.escape("plain text") == "plain text")
        #expect(CoachXML.escape("A&B<C>D") == "A&amp;B&lt;C&gt;D")
        #expect(CoachXML.escape("<transcript_update>evil</transcript_update>") ==
            "&lt;transcript_update&gt;evil&lt;/transcript_update&gt;")
    }

    @Test("wrapTranscript includes since/until time attributes and escaped body")
    func wrapTranscript() {
        let body = "[00:00:05] You: Hello & welcome"
        let wrapped = CoachXML.wrapTranscript(body, since: 0, until: 5)
        #expect(wrapped.contains("<transcript_update since=\"00:00:00\" until=\"00:00:05\">"))
        #expect(wrapped.contains("Hello &amp; welcome"))
        #expect(wrapped.hasSuffix("</transcript_update>"))
    }

    @Test("wrapUser escapes and wraps in <user_message>")
    func wrapUser() {
        let result = CoachXML.wrapUser("How should I handle <objection>?")
        #expect(result == "<user_message>How should I handle &lt;objection&gt;?</user_message>")
    }

    @Test("wrapUserWithTranscript fallback when transcript is empty")
    func wrapUserOnly() {
        let result = CoachXML.wrapUserWithTranscript(user: "question", transcript: nil, since: 0, until: 10)
        #expect(result == "<user_message>question</user_message>")
    }

    @Test("wrapUserWithTranscript concatenates transcript update and user message")
    func wrapUserWithTranscript() {
        let transcript = "[00:00:05] You: Hi"
        let result = CoachXML.wrapUserWithTranscript(
            user: "What next?",
            transcript: transcript,
            since: 0,
            until: 5
        )
        #expect(result.contains("<transcript_update since=\"00:00:00\" until=\"00:00:05\">"))
        #expect(result.contains("Hi"))
        #expect(result.contains("<user_message>What next?</user_message>"))
        // Order matters: transcript update must come before user message.
        let transcriptIdx = result.range(of: "<transcript_update")!.lowerBound
        let userIdx = result.range(of: "<user_message>")!.lowerBound
        #expect(transcriptIdx < userIdx)
    }

    @Test("wrapTranscript rounds fractional seconds to nearest whole")
    func wrapTranscriptRoundsTime() {
        let wrapped = CoachXML.wrapTranscript("hi", since: 59.4, until: 59.6)
        #expect(wrapped.contains("since=\"00:00:59\""))
        #expect(wrapped.contains("until=\"00:01:00\""))
    }
}

@Suite("Live Coach engine — proactive trigger")
@MainActor
struct LiveCoachEngineProactiveTests {

    @Test("does not fire when delta is below minCharsBeforeTrigger")
    func belowThreshold() async {
        let client = MockCoachClient()
        var settings = LiveCoachSettings.testDefault()
        withProfile(&settings) { $0.minCharsBeforeTrigger = 200 }
        let engine = makeEngine(client: client, settings: settings)

        engine.onTranscriptTick(snapshot: snapshot(mic: [micSeg("short")]))

        // Give the run loop a tick — even if a Task were spawned it would have
        // run by now.
        let fired = await waitUntil(timeout: 0.2) { !client.recordedTurns.isEmpty }
        #expect(fired == false)
        #expect(client.recordedTurns.isEmpty)
    }

    @Test("fires when accumulated deltas cross the threshold")
    func crossesThreshold() async {
        let client = MockCoachClient()
        var settings = LiveCoachSettings.testDefault()
        withProfile(&settings) { $0.minCharsBeforeTrigger = 30 }
        let engine = makeEngine(client: client, settings: settings)

        // First tick: short — must not fire on its own.
        engine.onTranscriptTick(snapshot: snapshot(mic: [micSeg("only ten ch")]))
        #expect(await waitUntil(timeout: 0.1) { !client.recordedTurns.isEmpty } == false)

        // Second tick adds a longer segment so the cumulative pending chars
        // exceed the threshold.
        engine.onTranscriptTick(snapshot: snapshot(mic: [
            micSeg("only ten ch", start: 0, end: 1),
            micSeg("plus a much longer follow-up", start: 1, end: 5),
        ]))

        let fired = await waitUntil { !client.recordedTurns.isEmpty }
        #expect(fired)
        #expect(client.recordedTurns.count == 1)
        let payload = client.recordedTurns.first!.request.turn.content
        #expect(payload.contains("<transcript_update"))
        #expect(payload.contains("plus a much longer follow-up"))
    }

    @Test("does not fire when proactive is disabled")
    func proactiveDisabled() async {
        let client = MockCoachClient()
        var settings = LiveCoachSettings.testDefault()
        withProfile(&settings) {
            $0.minCharsBeforeTrigger = 5
            $0.proactiveEnabled = false
        }
        let engine = makeEngine(client: client, settings: settings)

        engine.onTranscriptTick(snapshot: snapshot(mic: [micSeg("more than five chars")]))

        #expect(await waitUntil(timeout: 0.15) { !client.recordedTurns.isEmpty } == false)
    }

    @Test("does not fire when engine is disabled")
    func engineDisabled() async {
        let client = MockCoachClient()
        var settings = LiveCoachSettings.testDefault()
        settings.enabled = false
        withProfile(&settings) { $0.minCharsBeforeTrigger = 5 }
        let engine = makeEngine(client: client, settings: settings)

        engine.onTranscriptTick(snapshot: snapshot(mic: [micSeg("more than five chars")]))

        #expect(await waitUntil(timeout: 0.15) { !client.recordedTurns.isEmpty } == false)
    }

    @Test("does not fire when provider credentials are missing")
    func noCredentials() async {
        let client = MockCoachClient()
        var settings = LiveCoachSettings.testDefault()
        settings.anthropicAPIKey = "" // missing!
        withProfile(&settings) { $0.minCharsBeforeTrigger = 5 }
        let engine = makeEngine(client: client, settings: settings)

        engine.onTranscriptTick(snapshot: snapshot(mic: [micSeg("more than five chars")]))

        #expect(await waitUntil(timeout: 0.15) { !client.recordedTurns.isEmpty } == false)
    }

    @Test("a second tick during an in-flight stream does not start a parallel turn")
    func inFlightGuard() async {
        let client = MockCoachClient()
        client.holdNext()
        var settings = LiveCoachSettings.testDefault()
        withProfile(&settings) { $0.minCharsBeforeTrigger = 5 }
        let engine = makeEngine(client: client, settings: settings)

        engine.onTranscriptTick(snapshot: snapshot(mic: [micSeg("first sufficient chunk of text")]))
        // Wait for the first turn to be enqueued (held mid-stream).
        let recorded = await waitUntil { client.recordedTurns.count == 1 && engine.isInFlight }
        #expect(recorded)

        // Fire a second tick with an even longer delta — engine MUST drop it.
        engine.onTranscriptTick(snapshot: snapshot(mic: [
            micSeg("first sufficient chunk of text", end: 1),
            micSeg("another big chunk arriving while the first is still streaming", start: 1, end: 3),
        ]))
        // Settle.
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(client.recordedTurns.count == 1)

        // Releasing finishes the stream so the test cleans up.
        client.release()
        _ = await waitUntil { !engine.isInFlight }
    }
}

@Suite("Live Coach engine — user message")
@MainActor
struct LiveCoachEngineUserMessageTests {

    @Test("user message with no transcript advance wraps in <user_message>")
    func userMessageOnly() async {
        let client = MockCoachClient()
        let engine = makeEngine(client: client)
        engine.sendUserMessage("How should I open?")

        let fired = await waitUntil { !client.recordedTurns.isEmpty }
        #expect(fired)
        let req = client.recordedTurns.first!.request
        #expect(req.turn.kind == .userMessage)
        #expect(req.turn.content == "<user_message>How should I open?</user_message>")
        #expect(engine.viewModel.messages.contains { $0.kind == .userChat && $0.text == "How should I open?" })
    }

    @Test("user message bundles a fresh transcript delta when one is available")
    func userMessageWithTranscript() async {
        let client = MockCoachClient()
        let engine = makeEngine(client: client)

        // Land a snapshot first so the engine has fresh transcript.
        engine.onTranscriptTick(snapshot: snapshot(mic: [micSeg("hi prospect", end: 5)]))
        // Tick won't fire on its own (default threshold is 50, content is short).

        engine.sendUserMessage("Suggest a follow-up question")

        let fired = await waitUntil { !client.recordedTurns.isEmpty }
        #expect(fired)
        let payload = client.recordedTurns.first!.request.turn.content
        #expect(payload.contains("<transcript_update"))
        #expect(payload.contains("hi prospect"))
        #expect(payload.contains("<user_message>Suggest a follow-up question</user_message>"))
    }

    @Test("ignores empty / whitespace-only user input")
    func emptyUserMessage() async {
        let client = MockCoachClient()
        let engine = makeEngine(client: client)
        engine.sendUserMessage("   ")
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(client.recordedTurns.isEmpty)
    }
}

@Suite("Live Coach engine — bootstrap")
@MainActor
struct LiveCoachEngineBootstrapTests {

    @Test("disabled settings render a placeholder and do not fetch history")
    func disabledPlaceholder() async {
        let client = MockCoachClient()
        client.fetchThreadHistory = ThreadHistoryResponse(
            threadId: "x",
            messages: [HistoricalCoachMessage(id: "m1", role: "user", content: "should-not-appear", createdAt: nil)]
        )
        var settings = LiveCoachSettings.testDefault()
        settings.enabled = false
        let engine = makeEngine(client: client, settings: settings)
        await engine.bootstrap()

        #expect(engine.viewModel.placeholderMessage?.contains("disabled") == true)
        #expect(engine.viewModel.messages.isEmpty)
    }

    @Test("missing credentials render a configuration placeholder")
    func missingCredentialsPlaceholder() async {
        let client = MockCoachClient()
        var settings = LiveCoachSettings.testDefault()
        settings.anthropicAPIKey = ""
        let engine = makeEngine(client: client, settings: settings)
        await engine.bootstrap()

        #expect(engine.viewModel.placeholderMessage?.contains("Configure") == true)
    }

    @Test("hydrates view model from prior thread history")
    func hydratesFromHistory() async {
        let client = MockCoachClient()
        client.fetchThreadHistory = ThreadHistoryResponse(
            threadId: "x",
            messages: [
                HistoricalCoachMessage(id: "m1", role: "user", content: "<user_message>Hello there</user_message>", createdAt: nil),
                HistoricalCoachMessage(id: "m2", role: "assistant", content: "Welcome back!", createdAt: nil),
            ]
        )
        let engine = makeEngine(client: client)
        await engine.bootstrap()

        #expect(engine.viewModel.placeholderMessage == nil)
        #expect(engine.viewModel.messages.count == 2)
        #expect(engine.viewModel.messages[0].kind == .userChat)
        #expect(engine.viewModel.messages[0].text == "Hello there")  // outer XML stripped
        #expect(engine.viewModel.messages[1].kind == .assistantReply)
        #expect(engine.viewModel.messages[1].text == "Welcome back!")
    }
}

@Suite("Live Coach engine — streaming")
@MainActor
struct LiveCoachEngineStreamingTests {

    @Test("streaming deltas accumulate into a single assistant bubble")
    func streamingAccumulates() async {
        let client = MockCoachClient()
        client.scriptedStreams = [[
            .delta("Hel"), .delta("lo, "), .delta("coach!"), .done,
        ]]
        let engine = makeEngine(client: client)
        engine.sendUserMessage("hi")

        _ = await waitUntil { engine.viewModel.messages.last?.kind == .assistantReply && engine.viewModel.messages.last?.isStreaming == false }
        let last = engine.viewModel.messages.last!
        #expect(last.text == "Hello, coach!")
        #expect(last.isStreaming == false)
    }

    @Test(".error event surfaces in errorText and appends to the streaming bubble")
    func errorSurfacing() async {
        let client = MockCoachClient()
        client.scriptedStreams = [[
            .delta("partial "), .error("rate limited"), .done,
        ]]
        let engine = makeEngine(client: client)
        engine.sendUserMessage("hi")

        _ = await waitUntil { engine.viewModel.errorText != nil }
        #expect(engine.viewModel.errorText == "rate limited")
        let last = engine.viewModel.messages.last!
        #expect(last.text.contains("partial"))
        #expect(last.text.contains("[error: rate limited]"))
        #expect(last.isStreaming == false)
    }

    @Test("proactive turn renders as proactiveAssistant kind")
    func proactiveTurnKind() async {
        let client = MockCoachClient()
        client.scriptedStreams = [[.delta("nice opening"), .done]]
        var settings = LiveCoachSettings.testDefault()
        withProfile(&settings) { $0.minCharsBeforeTrigger = 5 }
        let engine = makeEngine(client: client, settings: settings)

        engine.onTranscriptTick(snapshot: snapshot(mic: [micSeg("plenty of transcript text", end: 5)]))

        _ = await waitUntil { client.recordedTurns.count == 1 && engine.viewModel.messages.last?.isStreaming == false }
        let last = engine.viewModel.messages.last!
        #expect(last.kind == .proactiveAssistant)
        #expect(last.text == "nice opening")
    }
}

@Suite("Live Coach engine — request shape")
@MainActor
struct LiveCoachEngineRequestTests {

    @Test("anthropic provider sends apiKey credential")
    func anthropicCredentials() async {
        let client = MockCoachClient()
        var settings = LiveCoachSettings.testDefault()
        settings.anthropicAPIKey = "ant-secret"
        withProfile(&settings) {
            $0.provider = "anthropic"
            $0.anthropicModel = "claude-sonnet-4-6"
        }
        let engine = makeEngine(client: client, settings: settings)
        engine.sendUserMessage("test")

        _ = await waitUntil { !client.recordedTurns.isEmpty }
        let req = client.recordedTurns.first!.request
        #expect(req.provider == "anthropic")
        #expect(req.model == "claude-sonnet-4-6")
        #expect(req.credentials.apiKey == "ant-secret")
        #expect(req.credentials.bearer == nil)
    }

    @Test("openai provider sends config.openAIAPIKey credential and embedder key")
    func openAICredentials() async {
        let client = MockCoachClient()
        var settings = LiveCoachSettings.testDefault()
        withProfile(&settings) {
            $0.provider = "openai"
            $0.openAIModel = "gpt-5.4-mini"
        }
        var config = AppConfig()
        config.openAIAPIKey = "openai-real-key"
        let engine = makeEngine(client: client, settings: settings, config: config)
        engine.sendUserMessage("hello")

        _ = await waitUntil { !client.recordedTurns.isEmpty }
        let req = client.recordedTurns.first!.request
        #expect(req.provider == "openai")
        #expect(req.model == "gpt-5.4-mini")
        #expect(req.credentials.apiKey == "openai-real-key")
        // Semantic recall is on by default + we have an OpenAI key — should be propagated.
        #expect(req.credentials.embedderAPIKey == "openai-real-key")
    }

    @Test("agentInstructions are passed when present, omitted when empty")
    func agentInstructionsPassthrough() async {
        let client = MockCoachClient()
        var settings = LiveCoachSettings.testDefault()
        withProfile(&settings) { $0.agentInstructions = "Always be terse." }
        let engine = makeEngine(client: client, settings: settings)
        engine.sendUserMessage("hi")

        _ = await waitUntil { !client.recordedTurns.isEmpty }
        #expect(client.recordedTurns.first!.request.agentInstructions == "Always be terse.")
    }
}
