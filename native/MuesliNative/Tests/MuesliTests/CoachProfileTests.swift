import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("CoachProfile + LiveCoachSettings migration")
struct CoachProfileMigrationTests {

    private func decode(_ json: String) throws -> LiveCoachSettings {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(LiveCoachSettings.self, from: data)
    }

    @Test("legacy config (flat fields) migrates Sales Coach with user's tweaks and auto-seeds other bundled defaults")
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

        // All bundled defaults present; the migrated Sales Coach carries the
        // user's legacy prompt + provider choice, others are freshly seeded.
        #expect(settings.profiles.count == CoachProfile.defaults.count)
        let sales = settings.profiles.first { $0.id == CoachProfile.salesCoachID }!
        #expect(sales.name == "Sales Coach")
        #expect(sales.provider == "openai")
        #expect(sales.systemPrompt == "Custom legacy prompt the user had tweaked")
        #expect(sales.agentInstructions == "extra instructions here")
        #expect(sales.proactiveEnabled == false)
        #expect(sales.minCharsBeforeTrigger == 350)
        #expect(settings.activeProfileID == sales.id)

        // Newly-seeded defaults keep their bundled defaults (not the legacy
        // provider). Sanity-check one.
        let retro = settings.profiles.first { $0.id == CoachProfile.retrospectiveID }!
        #expect(retro.provider == "anthropic")
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

    @Test("fresh init seeds all bundled default profiles and Sales Coach is the active default")
    func freshDefaults() {
        let settings = LiveCoachSettings()
        let names = settings.profiles.map(\.name)
        #expect(names.contains("Sales Coach"))
        #expect(names.contains("Team Meeting Facilitator"))
        #expect(names.contains("Executive Briefing"))
        #expect(names.contains("Retrospective Coach"))
        #expect(names.contains("1:1 Coach"))
        #expect(settings.profiles.count == CoachProfile.defaults.count)
        #expect(settings.activeProfile.name == "Sales Coach")
    }

    @Test("legacy-migrated config picks up bundled default profiles on next load")
    func legacyGetsNewDefaults() throws {
        // Simulate a migrated user: legacy flat fields, no profiles array yet.
        let legacy = """
        {
          "enabled": true,
          "system_prompt": "Pre-profiles sales prompt"
        }
        """
        let settings = try decode(legacy)
        // Should have Sales Coach (migrated from legacy) plus all OTHER
        // bundled defaults auto-seeded.
        #expect(settings.profiles.count == CoachProfile.defaults.count)
        let names = settings.profiles.map(\.name)
        #expect(names.contains("Sales Coach"))
        #expect(names.contains("Team Meeting Facilitator"))
        #expect(names.contains("Retrospective Coach"))
        #expect(names.contains("1:1 Coach"))
        // Migrated Sales Coach keeps the user's legacy prompt.
        let sales = settings.profiles.first { $0.name == "Sales Coach" }!
        #expect(sales.systemPrompt == "Pre-profiles sales prompt")
    }

    @Test("deleted defaults stay deleted after reload")
    func deletedDefaultsStayDeleted() throws {
        // User on a previous version saw three defaults, then deleted the
        // Executive Briefing. Config now has 2 profiles and the
        // seeded_default_ids set contains all 3 old defaults.
        let partial = """
        {
          "enabled": true,
          "seeded_default_ids": [
            "\(CoachProfile.salesCoachID.uuidString)",
            "\(CoachProfile.teamMeetingID.uuidString)",
            "\(CoachProfile.executiveBriefingID.uuidString)"
          ],
          "profiles": [
            {
              "id": "\(CoachProfile.salesCoachID.uuidString)",
              "name": "Sales Coach",
              "provider": "anthropic",
              "anthropic_model": "claude-sonnet-4-6",
              "openai_model": "gpt-5.4-mini",
              "chatgpt_model": "gpt-5.4-mini",
              "system_prompt": "sales",
              "agent_instructions": "",
              "working_memory_template": "",
              "proactive_enabled": true,
              "min_chars_before_trigger": 200
            },
            {
              "id": "\(CoachProfile.teamMeetingID.uuidString)",
              "name": "Team Meeting Facilitator",
              "provider": "anthropic",
              "anthropic_model": "claude-sonnet-4-6",
              "openai_model": "gpt-5.4-mini",
              "chatgpt_model": "gpt-5.4-mini",
              "system_prompt": "team",
              "agent_instructions": "",
              "working_memory_template": "",
              "proactive_enabled": true,
              "min_chars_before_trigger": 200
            }
          ]
        }
        """
        let settings = try decode(partial)
        let names = settings.profiles.map(\.name)
        // Deleted Executive Briefing must not come back.
        #expect(!names.contains("Executive Briefing"))
        // But NEW bundled defaults (that weren't in seeded_default_ids) do seed in.
        #expect(names.contains("Retrospective Coach"))
        #expect(names.contains("1:1 Coach"))
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
