import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("CoachProfile + LiveCoachSettings migration")
struct CoachProfileMigrationTests {

    private func decode(_ json: String) throws -> LiveCoachSettings {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(LiveCoachSettings.self, from: data)
    }

    @Test("legacy config (flat fields, no profiles array) migrates to a single Sales Coach profile")
    func legacyMigration() throws {
        let legacy = """
        {
          "enabled": true,
          "provider": "openai",
          "anthropic_model": "claude-sonnet-4-6",
          "openai_model": "gpt-5.4-mini",
          "chatgpt_model": "gpt-5.4-mini",
          "anthropic_api_key": "ant-key",
          "system_prompt": "Custom legacy prompt the user had tweaked",
          "agent_instructions": "extra instructions here",
          "proactive_enabled": false,
          "min_chars_before_trigger": 350,
          "enable_semantic_recall": false,
          "preserve_thread_across_meetings": false
        }
        """
        let settings = try decode(legacy)

        #expect(settings.enabled)
        #expect(settings.anthropicAPIKey == "ant-key")
        #expect(settings.enableSemanticRecall == false)
        #expect(settings.preserveThreadAcrossMeetings == false)

        // Exactly one profile, named Sales Coach, carrying the legacy fields.
        #expect(settings.profiles.count == 1)
        let p = settings.profiles[0]
        #expect(p.name == "Sales Coach")
        #expect(p.id == CoachProfile.salesCoachID)
        #expect(p.provider == "openai")
        #expect(p.systemPrompt == "Custom legacy prompt the user had tweaked")
        #expect(p.agentInstructions == "extra instructions here")
        #expect(p.proactiveEnabled == false)
        #expect(p.minCharsBeforeTrigger == 350)
        #expect(settings.activeProfileID == p.id)
    }

    @Test("modern config with profiles array round-trips and ignores legacy keys")
    func modernRoundTrip() throws {
        var original = LiveCoachSettings()
        original.enabled = true
        original.anthropicAPIKey = "ant-key"
        let custom = CoachProfile(name: "Custom Profile", systemPrompt: "Be terse.")
        original.profiles = [custom]
        original.activeProfileID = custom.id

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LiveCoachSettings.self, from: encoded)
        #expect(decoded == original)
    }

    @Test("fresh init seeds three default profiles and Sales Coach is the active default")
    func freshDefaults() {
        let settings = LiveCoachSettings()
        #expect(settings.profiles.count == 3)
        #expect(settings.profiles.map(\.name) == [
            "Sales Coach",
            "Team Meeting Facilitator",
            "Executive Briefing",
        ])
        #expect(settings.activeProfile.name == "Sales Coach")
    }

    @Test("activeProfile falls back gracefully when activeProfileID points at a deleted profile")
    func activeProfileFallback() {
        var settings = LiveCoachSettings()
        settings.activeProfileID = UUID()  // not in profiles
        // Should fall back to first profile rather than crash.
        #expect(settings.activeProfile.id == settings.profiles[0].id)
    }
}

@Suite("Engine uses active profile, not flat settings")
@MainActor
struct CoachProfileEngineWiringTests {

    @Test("request resourceId is scoped per profile id")
    func resourceIsolation() async {
        let client = MockCoachClient()
        var settings = LiveCoachSettings()
        settings.enabled = true
        settings.anthropicAPIKey = "ant"
        let alpha = CoachProfile(name: "Alpha", systemPrompt: "alpha prompt")
        let beta = CoachProfile(name: "Beta", systemPrompt: "beta prompt")
        settings.profiles = [alpha, beta]

        // Engine bound to alpha.
        let engineAlpha = LiveCoachEngine(
            client: client,
            settings: settings,
            profile: alpha,
            config: AppConfig(),
            threadId: "meeting-1"
        )
        engineAlpha.sendUserMessage("hi")
        _ = await waitUntilLocal { client.recordedTurns.count == 1 }
        let alphaReq = client.recordedTurns[0].request
        #expect(alphaReq.resourceId == "profile-\(alpha.id.uuidString.lowercased())")
        #expect(alphaReq.systemPrompt == "alpha prompt")
        #expect(alphaReq.threadId.hasPrefix("meeting-1-profile-"))
        #expect(alphaReq.threadId.contains(alpha.id.uuidString.lowercased()))

        // Engine bound to beta.
        let engineBeta = LiveCoachEngine(
            client: client,
            settings: settings,
            profile: beta,
            config: AppConfig(),
            threadId: "meeting-1"
        )
        engineBeta.sendUserMessage("hi")
        _ = await waitUntilLocal { client.recordedTurns.count == 2 }
        let betaReq = client.recordedTurns[1].request
        #expect(betaReq.resourceId == "profile-\(beta.id.uuidString.lowercased())")
        #expect(betaReq.systemPrompt == "beta prompt")
        #expect(alphaReq.resourceId != betaReq.resourceId)
        // Same baseThreadId but different profile id → different effective thread.
        #expect(alphaReq.threadId != betaReq.threadId)
    }

    @Test("workingMemoryTemplate is sent on the wire when set, omitted when blank")
    func templatePassthrough() async {
        let client = MockCoachClient()
        var settings = LiveCoachSettings()
        settings.enabled = true
        settings.anthropicAPIKey = "ant"
        var withTemplate = CoachProfile(name: "WithTemplate", systemPrompt: "p")
        withTemplate.workingMemoryTemplate = "# Custom Template\n- Field:"
        let withoutTemplate = CoachProfile(name: "Plain", systemPrompt: "p")
        settings.profiles = [withTemplate, withoutTemplate]

        let engineWith = LiveCoachEngine(
            client: client, settings: settings, profile: withTemplate,
            config: AppConfig(), threadId: "t"
        )
        engineWith.sendUserMessage("x")
        _ = await waitUntilLocal { client.recordedTurns.count == 1 }
        #expect(client.recordedTurns[0].request.workingMemoryTemplate == "# Custom Template\n- Field:")

        let engineWithout = LiveCoachEngine(
            client: client, settings: settings, profile: withoutTemplate,
            config: AppConfig(), threadId: "t"
        )
        engineWithout.sendUserMessage("y")
        _ = await waitUntilLocal { client.recordedTurns.count == 2 }
        #expect(client.recordedTurns[1].request.workingMemoryTemplate == nil)
    }

    @Test("per-profile minCharsBeforeTrigger overrides any global default")
    func perProfileTrigger() async {
        let client = MockCoachClient()
        var settings = LiveCoachSettings()
        settings.enabled = true
        settings.anthropicAPIKey = "ant"
        var p = CoachProfile(name: "Eager", systemPrompt: "p")
        p.minCharsBeforeTrigger = 5
        settings.profiles = [p]
        settings.activeProfileID = p.id

        let engine = LiveCoachEngine(
            client: client, settings: settings, profile: p,
            config: AppConfig(), threadId: "t"
        )
        engine.onTranscriptTick(snapshot: CoachTranscriptSnapshot(
            mic: [SpeechSegment(start: 0, end: 1, text: "hello world")],
            system: [], diarization: [], labelMap: [:], meetingStart: Date()
        ))
        let fired = await waitUntilLocal { client.recordedTurns.count == 1 }
        #expect(fired)
    }
}

// Local copy of the helper so this suite isn't coupled to the other test
// file's private `waitUntil`.
@MainActor
private func waitUntilLocal(timeout: TimeInterval = 1.0, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}
