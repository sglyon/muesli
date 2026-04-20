import Foundation
import MuesliCore

struct BackendOption: Equatable {
    let backend: String
    let model: String
    let label: String
    let sizeLabel: String
    let description: String
    let recommended: Bool

    static let parakeetMultilingual = BackendOption(
        backend: "fluidaudio",
        model: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        label: "Parakeet v3",
        sizeLabel: "~450 MB",
        description: "Multilingual, 25 languages. Runs on Apple Neural Engine.",
        recommended: true
    )

    static let parakeetEnglish = BackendOption(
        backend: "fluidaudio",
        model: "FluidInference/parakeet-tdt-0.6b-v2-coreml",
        label: "Parakeet v2",
        sizeLabel: "~450 MB",
        description: "English-only, highest recall. Runs on Apple Neural Engine.",
        recommended: false
    )

    static let whisperSmall = BackendOption(
        backend: "whisper",
        model: "small.en",
        label: "Whisper Small",
        sizeLabel: "~250 MB",
        description: "Fast, English-optimized. Runs on Apple Neural Engine via CoreML.",
        recommended: false
    )

    static let whisperMedium = BackendOption(
        backend: "whisper",
        model: "medium.en",
        label: "Whisper Medium",
        sizeLabel: "~1.5 GB",
        description: "Better accuracy, English-only. Runs on Apple Neural Engine via CoreML.",
        recommended: false
    )

    static let whisperLargeTurbo = BackendOption(
        backend: "whisper",
        model: "large-v3-v20240930_626MB",
        label: "Whisper Large Turbo",
        sizeLabel: "~626 MB",
        description: "Highest accuracy, multilingual. Quantized CoreML for faster inference.",
        recommended: false
    )

    static let nemotronStreaming = BackendOption(
        backend: "nemotron",
        model: "FluidInference/nemotron-speech-streaming-en-0.6b-coreml",
        label: "Nemotron Streaming (Experimental)",
        sizeLabel: "~600 MB",
        description: "Experimental. NVIDIA streaming RNNT. English-only. Handsfree mode only. No punctuation (RNNT limitation). Append-only — no corrections.",
        recommended: false
    )

    static let canaryQwen = BackendOption(
        backend: "canary",
        model: "phequals/canary-qwen-2.5b-coreml-int8",
        label: "Canary Qwen",
        sizeLabel: "~2.5 GB",
        description: "INT8 CoreML, autoregressive, experimental. English-first. First use warms up slowly. Final transcript after stop in v1.",
        recommended: false
    )

    static let cohereTranscribe = BackendOption(
        backend: "cohere",
        model: "phequals/cohere-transcribe-coreml-mixed-precision",
        label: "Cohere Transcribe",
        sizeLabel: "~3.8 GB",
        description: "Mixed precision (FP16 encoder + INT8 decoder). English. High accuracy (#1 Open ASR Leaderboard). Final transcript after stop. May decode hallucinated text during silence — use in quiet environments or with VAD.",
        recommended: false
    )

    // Default alias
    static let whisper = parakeetMultilingual

    static let parakeetFamily: [BackendOption] = [
        .parakeetMultilingual, .parakeetEnglish,
    ]

    static let whisperFamily: [BackendOption] = [
        .whisperSmall, .whisperMedium, .whisperLargeTurbo,
    ]

    static let qwen3Asr = BackendOption(
        backend: "qwen",
        model: "FluidInference/qwen3-asr-0.6b-coreml",
        label: "Qwen3 ASR",
        sizeLabel: "~1.3 GB",
        description: "Multilingual, 52 languages. Slower than Parakeet (~2-3s). First use takes ~30s to warm up.",
        recommended: false
    )

    static let experimental: [BackendOption] = [
        .qwen3Asr, .canaryQwen, .nemotronStreaming,
    ]

    /// Models available for download and use.
    static let all: [BackendOption] = parakeetFamily + whisperFamily + [.cohereTranscribe] + experimental

    /// Models coming soon — shown greyed out in the Models tab.
    static let comingSoon: [BackendOption] = []

    /// Only models that have been downloaded and are ready for inference.
    static var downloaded: [BackendOption] {
        all.filter { $0.isDownloaded }
    }

    /// Check if this model's files exist on disk.
    var isDownloaded: Bool {
        let fm = FileManager.default
        switch backend {
        case "whisper":
            return WhisperKitTranscriber.isModelDownloaded(model)
        case "fluidaudio":
            let supportDir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/FluidAudio/Models")
            if model.contains("parakeet") {
                let version = model.contains("v2") ? "v2" : "v3"
                if let contents = try? fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil) {
                    return contents.contains { $0.lastPathComponent.contains("parakeet") && $0.lastPathComponent.contains(version) }
                }
            }
            return false
        case "qwen":
            let supportDir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/FluidAudio/Models/qwen3-asr-0.6b-coreml")
            return fm.fileExists(atPath: supportDir.appendingPathComponent("int8/vocab.json").path)
                || fm.fileExists(atPath: supportDir.appendingPathComponent("f32/vocab.json").path)
        case "nemotron":
            let path = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/muesli/models/nemotron-560ms/encoder/encoder_int8.mlmodelc")
            return fm.fileExists(atPath: path.path)
        case "canary":
            return CanaryQwenModelStore.isAvailableLocally()
        case "cohere":
            return CohereTranscribeModelStore.isAvailableLocally()
        default:
            return false
        }
    }
}

struct SummaryModelPreset {
    let id: String
    let label: String

    static let openAIModels: [SummaryModelPreset] = [
        SummaryModelPreset(id: "gpt-5.4-mini", label: "GPT-5.4 Mini (default)"),
        SummaryModelPreset(id: "gpt-5.4-nano", label: "GPT-5.4 Nano"),
        SummaryModelPreset(id: "gpt-5.4", label: "GPT-5.4"),
        SummaryModelPreset(id: "gpt-5.4-pro", label: "GPT-5.4 Pro"),
        SummaryModelPreset(id: "gpt-5-mini", label: "GPT-5 Mini"),
        SummaryModelPreset(id: "gpt-5.2", label: "GPT-5.2"),
    ]

    static let chatGPTModels: [SummaryModelPreset] = [
        SummaryModelPreset(id: "gpt-5.4-mini", label: "GPT-5.4 Mini (default)"),
        SummaryModelPreset(id: "gpt-5.4-nano", label: "GPT-5.4 Nano"),
        SummaryModelPreset(id: "gpt-5.4", label: "GPT-5.4"),
        SummaryModelPreset(id: "gpt-5.2", label: "GPT-5.2"),
        SummaryModelPreset(id: "gpt-4o", label: "GPT-4o"),
    ]

    static let openRouterModels: [SummaryModelPreset] = [
        SummaryModelPreset(id: "stepfun/step-3.5-flash:free", label: "Step 3.5 Flash (free, 256k ctx)"),
        SummaryModelPreset(id: "nvidia/nemotron-3-super-120b-a12b:free", label: "Nemotron 3 Super 120B (free, 262k ctx)"),
        SummaryModelPreset(id: "nvidia/nemotron-3-nano-30b-a3b:free", label: "Nemotron 3 Nano 30B (free, 256k ctx)"),
        SummaryModelPreset(id: "arcee-ai/trinity-large-preview:free", label: "Trinity Large (free, 131k ctx)"),
    ]
}

struct MeetingSummaryBackendOption: Equatable {
    let backend: String
    let label: String

    static let openAI = MeetingSummaryBackendOption(
        backend: "openai",
        label: "OpenAI"
    )

    static let openRouter = MeetingSummaryBackendOption(
        backend: "openrouter",
        label: "OpenRouter"
    )

    static let chatGPT = MeetingSummaryBackendOption(
        backend: "chatgpt",
        label: "ChatGPT"
    )

    static let all: [MeetingSummaryBackendOption] = [.openAI, .openRouter, .chatGPT]
}

struct PostProcessorOption: Identifiable, Equatable {
    let id: String
    let label: String
    let sizeLabel: String
    let description: String
    let downloadURL: URL
    let filename: String

    var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/muesli/models/postproc-\(id)", isDirectory: true)
    }

    var modelURL: URL {
        cacheDirectory.appendingPathComponent(filename)
    }

    var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    // Fine-tuned Qwen3-0.6B trained on Muesli dictation correction data.
    // HF repo must be public (or token-gated) before distributing alpha builds.
    static let finetunedV2 = PostProcessorOption(
        id: "qwen3-postproc-v2",
        label: "Post-Proc v2 (Finetuned)",
        sizeLabel: "~390 MB",
        description: "Fine-tuned on Muesli dictation data. Best for filler removal, deletion cues, and spoken list formatting.",
        downloadURL: URL(string: "https://huggingface.co/phequals/qwen3-postproc-v2/resolve/main/qwen3-postproc-v2-q4_k_m.gguf")!,
        filename: "qwen3-postproc-v2-q4_k_m.gguf"
    )

    // Vanilla Qwen3.5-0.8B. Stable for basic cleanup; does not reliably convert spoken list cues.
    static let qwen35_0_8b = PostProcessorOption(
        id: "qwen35-0.8b",
        label: "Qwen3.5 0.8B",
        sizeLabel: "~533 MB",
        description: "Vanilla Qwen3.5-0.8B. Good for typo correction and filler removal. Spoken list formatting is unreliable.",
        downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf")!,
        filename: "Qwen3.5-0.8B-Q4_K_M.gguf"
    )

    // Fine-tuned Qwen3.5-0.8B v3 trained on Muesli dictation correction data.
    static let finetunedV3 = PostProcessorOption(
        id: "qwen35-postproc-v3",
        label: "Post-Proc v3 (Finetuned)",
        sizeLabel: "~505 MB",
        description: "Fine-tuned Qwen3.5-0.8B on Muesli dictation data. Improved over v2 on filler removal, deletion cues, and spoken list formatting.",
        downloadURL: URL(string: "https://huggingface.co/phequals/qwen35-postproc-v3-gguf/resolve/main/qwen35-postproc-v3-Q4_K_M.gguf")!,
        filename: "qwen35-postproc-v3-Q4_K_M.gguf"
    )

    static let all: [PostProcessorOption] = [.finetunedV3, .finetunedV2, .qwen35_0_8b]
    static let defaultOption: PostProcessorOption = .finetunedV3

    static var downloaded: [PostProcessorOption] {
        all.filter(\.isDownloaded)
    }

    static var downloadedIDs: Set<String> {
        Set(downloaded.map(\.id))
    }

    static func resolve(id: String) -> PostProcessorOption {
        all.first { $0.id == id } ?? defaultOption
    }

    static func firstDownloaded(excluding excludedID: String? = nil) -> PostProcessorOption? {
        firstDownloaded(excluding: excludedID, downloadedIDs: downloadedIDs)
    }

    static func firstDownloaded(excluding excludedID: String? = nil, downloadedIDs: Set<String>) -> PostProcessorOption? {
        all.first { option in
            option.id != excludedID && downloadedIDs.contains(option.id)
        }
    }

    static func resolveDownloaded(id: String) -> PostProcessorOption? {
        resolveDownloaded(id: id, downloadedIDs: downloadedIDs)
    }

    static func resolveDownloaded(id: String, downloadedIDs: Set<String>) -> PostProcessorOption? {
        let resolved = resolve(id: id)
        if downloadedIDs.contains(resolved.id) { return resolved }
        return firstDownloaded(downloadedIDs: downloadedIDs)
    }

    static func runtimeOption(id: String) -> PostProcessorOption? {
        runtimeOption(
            id: id,
            downloadedIDs: downloadedIDs,
            hasDevOverride: Qwen3PostProcessorConfig.devOverrideURL() != nil
        )
    }

    static func runtimeOption(id: String, downloadedIDs: Set<String>, hasDevOverride: Bool) -> PostProcessorOption? {
        let configured = resolve(id: id)
        if downloadedIDs.contains(configured.id) || hasDevOverride { return configured }
        return firstDownloaded(downloadedIDs: downloadedIDs)
    }

    static let defaultSystemPrompt = """
    Clean up speech-to-text transcription. Only make changes when there is a clear error. If the text is already correct, output it exactly as-is.

    You may: fix obvious misspellings, remove filler words (um, uh, like), apply 'scratch that' deletions, and format numbered or bullet lists when dictated.

    Do not: paraphrase, reword, add words, remove meaningful words, change the meaning in any way, wrap the output in markdown, code fences, tags, labels, or commentary, or repeat the output more than once. Preserve the speaker's original phrasing.
    """
}

struct CustomWord: Codable, Equatable, Identifiable {
    var id = UUID()
    var word: String
    var replacement: String?
    var matchingThreshold: Double = 0.85

    enum CodingKeys: String, CodingKey {
        case id
        case word
        case replacement
        case matchingThreshold = "matching_threshold"
    }

    init(id: UUID = UUID(), word: String, replacement: String?, matchingThreshold: Double = 0.85) {
        self.id = id
        self.word = word
        self.replacement = replacement
        self.matchingThreshold = Self.clampedThreshold(matchingThreshold)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        word = try c.decode(String.self, forKey: .word)
        replacement = try c.decodeIfPresent(String.self, forKey: .replacement)
        matchingThreshold = Self.clampedThreshold(try c.decodeIfPresent(Double.self, forKey: .matchingThreshold) ?? 0.85)
    }

    var displayLabel: String {
        if let replacement, !replacement.isEmpty {
            return "\(word) → \(replacement)"
        }
        return word
    }

    var targetWord: String {
        replacement ?? word
    }

    private static func clampedThreshold(_ value: Double) -> Double {
        min(max(value, 0.70), 0.95)
    }
}

enum IndicatorAnchor: String, Codable, CaseIterable {
    case topLeading = "top_leading"
    case topCenter = "top_center"
    case topTrailing = "top_trailing"
    case midLeading = "mid_leading"
    case midTrailing = "mid_trailing"
    case bottomLeading = "bottom_leading"
    case bottomCenter = "bottom_center"
    case bottomTrailing = "bottom_trailing"
    case custom = "custom"

    var label: String {
        switch self {
        case .topLeading: return "Top Left"
        case .topCenter: return "Top Center"
        case .topTrailing: return "Top Right"
        case .midLeading: return "Middle Left"
        case .midTrailing: return "Middle Right"
        case .bottomLeading: return "Bottom Left"
        case .bottomCenter: return "Bottom Center"
        case .bottomTrailing: return "Bottom Right"
        case .custom: return "Custom"
        }
    }
}

struct HotkeyConfig: Codable, Equatable {
    var keyCode: UInt16 = 55
    var label: String = "Left Cmd"

    static func label(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 55: return "Left Cmd"
        case 54: return "Right Cmd"
        case 63: return "Fn"
        case 59: return "Left Ctrl"
        case 62: return "Right Ctrl"
        case 58: return "Left Option"
        case 61: return "Right Option"
        case 56: return "Left Shift"
        case 60: return "Right Shift"
        default: return nil
        }
    }

    static let `default` = HotkeyConfig()
}

/// One configurable Live Coach persona (sales call, team retro, exec
/// briefing, etc.). Each profile carries everything that varies by use case:
/// the prompt, the model, the working-memory template (what the coach should
/// keep notes about). Cross-cutting state (API keys, semantic-recall toggle)
/// lives on `LiveCoachSettings`.
struct CoachProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var provider: String                          // "anthropic" | "openai" | "chatgpt"
    var anthropicModel: String
    var openAIModel: String
    var chatGPTModel: String
    var systemPrompt: String
    var agentInstructions: String
    /// Mastra working-memory template — sent per-turn so the sidecar can
    /// scope working memory by profile. Empty means "use sidecar default".
    var workingMemoryTemplate: String
    var proactiveEnabled: Bool
    var minCharsBeforeTrigger: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case provider
        case anthropicModel = "anthropic_model"
        case openAIModel = "openai_model"
        case chatGPTModel = "chatgpt_model"
        case systemPrompt = "system_prompt"
        case agentInstructions = "agent_instructions"
        case workingMemoryTemplate = "working_memory_template"
        case proactiveEnabled = "proactive_enabled"
        case minCharsBeforeTrigger = "min_chars_before_trigger"
    }

    init(
        id: UUID = UUID(),
        name: String,
        provider: String = "anthropic",
        anthropicModel: String = "claude-sonnet-4-6",
        openAIModel: String = "gpt-5.4-mini",
        chatGPTModel: String = "gpt-5.4-mini",
        systemPrompt: String,
        agentInstructions: String = "",
        workingMemoryTemplate: String = "",
        proactiveEnabled: Bool = true,
        minCharsBeforeTrigger: Int = 200
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.anthropicModel = anthropicModel
        self.openAIModel = openAIModel
        self.chatGPTModel = chatGPTModel
        self.systemPrompt = systemPrompt
        self.agentInstructions = agentInstructions
        self.workingMemoryTemplate = workingMemoryTemplate
        self.proactiveEnabled = proactiveEnabled
        self.minCharsBeforeTrigger = minCharsBeforeTrigger
    }

    var activeModel: String {
        switch provider {
        case "anthropic": return anthropicModel
        case "openai": return openAIModel
        case "chatgpt": return chatGPTModel
        default: return ""
        }
    }

    static let salesCoachID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let teamMeetingID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let executiveBriefingID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let retrospectiveID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    static let oneOnOneID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

    static let salesCoachPrompt = """
    You are a real-time sales coach for Spencer Lyon at Arete Intelligence (data engineering, data science, and AI transformation for mid-market companies). You observe a live meeting transcript. When you receive a <transcript_update>, provide 1-3 short, actionable coaching tips — tone, questions to ask next, objections to anticipate, or discovery threads to pull on. When you receive a <user_message>, answer directly. Keep replies tight (under 120 words unless asked).
    """

    static let teamMeetingPrompt = """
    You are a real-time facilitator's coach for a team meeting. Watch the transcript for: action items being committed (and by whom), decisions being made (and any unstated assumptions), people being talked over, topics drifting, and questions left unanswered. When you receive a <transcript_update>, surface 1-3 short observations or suggested interventions. When you receive a <user_message>, answer it directly. Plain text, under 120 words unless asked.
    """

    static let executiveBriefingPrompt = """
    You are a real-time coach for Spencer Lyon presenting to senior leadership at his firm. Watch for: jargon that needs translating, claims that lack a number, leadership concerns being avoided, and openings to connect the work back to firm-level priorities. When you receive a <transcript_update>, give 1-3 short tips on framing, what to anticipate, or which thread to pull. When you receive a <user_message>, answer it directly. Plain text, under 120 words unless asked.
    """

    static let retrospectivePrompt = """
    You are a real-time coach for a team retrospective. Your job: keep the conversation productive, specific, and blame-free. Watch for: vague complaints that need concrete examples, root causes being skipped in favor of symptoms, "we should do X" declarations that nobody owns, silence where junior voices should be heard, and patterns that recur from previous retros. When you receive a <transcript_update>, give 1-3 short observations or suggested interventions the facilitator could use. When you receive a <user_message>, answer directly. Plain text, under 120 words unless asked.
    """

    static let oneOnOnePrompt = """
    You are a real-time coach for a manager running a 1:1. Your job: help the manager listen better, notice what's unsaid, and surface issues early. Watch for: the report raising a concern that gets brushed past, the manager filling silence instead of letting the report talk, follow-ups from prior 1:1s that should be revisited, signals of burnout or disengagement, and growth conversations being deferred. When you receive a <transcript_update>, offer 1-3 short nudges — a question to ask, a thread to slow down on, or something to explicitly acknowledge. When you receive a <user_message>, answer directly. Plain text, under 120 words unless asked.
    """

    static let salesWorkingMemory = """
    # Muesli User Profile

    ## About
    - Name:
    - Company / offering: (default: Spencer Lyon @ Arete Intelligence — data engineering, data science, AI transformation for mid-market companies)
    - Common buyer personas:

    ## Pitch Patterns
    - Strengths observed:
    - Recurring weaknesses / tells:
    - Go-to discovery questions that have worked:

    ## Prospect Intel (most-recent-first)
    - [Prospect / company] — [date] — key concerns, stage, next step:

    ## Objection Library
    - [Objection] → [best response seen so far]
    """

    static let teamMeetingWorkingMemory = """
    # Team Meeting Patterns

    ## Recurring Action Items
    - [Owner] — [item] — [last seen date]

    ## Decisions Made
    - [Decision] — [date] — [rationale captured]

    ## Team Dynamics
    - Voices that tend to dominate:
    - Voices that tend to go quiet:
    - Topics that consistently derail:

    ## Open Threads
    - [Question still unanswered after N meetings]
    """

    static let executiveBriefingWorkingMemory = """
    # Leadership Briefing Notes

    ## Stakeholder Map
    - [Name] — [role] — [known priorities / hot buttons]

    ## Recurring Questions Asked
    - [Question] — [best answer prepared]

    ## Firm-Level Themes
    - Strategic priorities currently in play:
    - Numbers leadership cares about:

    ## Past Pushback
    - [Topic] — [pushback received] — [follow-up still owed]
    """

    static let retrospectiveWorkingMemory = """
    # Retrospective Patterns

    ## Recurring Themes (seen across multiple retros)
    - [Theme] — [first noticed] — [status / still open]

    ## Systemic Issues vs. Incidents
    - Systemic:
    - One-off:

    ## Action Items From Prior Retros
    - [Item] — [owner] — [status]

    ## Team Sentiment Signals
    - Energy / morale observations:
    - Voices commonly unheard:
    """

    static let oneOnOneWorkingMemory = """
    # 1:1 Running Notes

    ## About the Report
    - Name / role:
    - Current priorities:
    - Development goals:

    ## Open Follow-Ups (most-recent-first)
    - [Topic] — [promised on date] — [status]

    ## Concerns Raised
    - [Concern] — [date] — [how it was handled]

    ## Manager Reminders
    - Things to explicitly acknowledge next time:
    - Patterns to watch for (e.g., burnout signals, growth stalls):
    """

    static let defaults: [CoachProfile] = [
        CoachProfile(
            id: salesCoachID,
            name: "Sales Coach",
            systemPrompt: salesCoachPrompt,
            workingMemoryTemplate: salesWorkingMemory
        ),
        CoachProfile(
            id: teamMeetingID,
            name: "Team Meeting Facilitator",
            systemPrompt: teamMeetingPrompt,
            workingMemoryTemplate: teamMeetingWorkingMemory
        ),
        CoachProfile(
            id: executiveBriefingID,
            name: "Executive Briefing",
            systemPrompt: executiveBriefingPrompt,
            workingMemoryTemplate: executiveBriefingWorkingMemory
        ),
        CoachProfile(
            id: retrospectiveID,
            name: "Retrospective Coach",
            systemPrompt: retrospectivePrompt,
            workingMemoryTemplate: retrospectiveWorkingMemory
        ),
        CoachProfile(
            id: oneOnOneID,
            name: "1:1 Coach",
            systemPrompt: oneOnOnePrompt,
            workingMemoryTemplate: oneOnOneWorkingMemory
        ),
    ]
}

struct LiveCoachSettings: Codable, Equatable {
    var enabled: Bool = false
    var anthropicAPIKey: String = ""              // shared across profiles
    var enableSemanticRecall: Bool = true
    var preserveThreadAcrossMeetings: Bool = true
    var profiles: [CoachProfile] = CoachProfile.defaults
    /// The profile selected by default when a meeting starts. The panel can
    /// still swap profile mid-meeting without changing this value.
    var activeProfileID: UUID = CoachProfile.salesCoachID
    /// IDs of bundled default profiles the user has been offered. Lets new
    /// defaults auto-seed on upgrade without re-adding ones the user has
    /// explicitly deleted.
    var seededDefaultIDs: Set<UUID> = Set(CoachProfile.defaults.map(\.id))

    /// Looks up the active profile, falling back to the first available or a
    /// freshly-built Sales Coach if profiles is somehow empty.
    var activeProfile: CoachProfile {
        if let match = profiles.first(where: { $0.id == activeProfileID }) {
            return match
        }
        return profiles.first ?? CoachProfile(
            id: CoachProfile.salesCoachID,
            name: "Sales Coach",
            systemPrompt: CoachProfile.salesCoachPrompt,
            workingMemoryTemplate: CoachProfile.salesWorkingMemory
        )
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case anthropicAPIKey = "anthropic_api_key"
        case enableSemanticRecall = "enable_semantic_recall"
        case preserveThreadAcrossMeetings = "preserve_thread_across_meetings"
        case profiles
        case activeProfileID = "active_profile_id"
        case seededDefaultIDs = "seeded_default_ids"

        // Legacy keys retained so we can migrate older configs that pre-date
        // profiles. Not encoded back out — only read in init(from:).
        case legacyProvider = "provider"
        case legacyAnthropicModel = "anthropic_model"
        case legacyOpenAIModel = "openai_model"
        case legacyChatGPTModel = "chatgpt_model"
        case legacySystemPrompt = "system_prompt"
        case legacyAgentInstructions = "agent_instructions"
        case legacyProactiveEnabled = "proactive_enabled"
        case legacyMinCharsBeforeTrigger = "min_chars_before_trigger"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LiveCoachSettings()
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? defaults.enabled
        anthropicAPIKey = (try? c.decode(String.self, forKey: .anthropicAPIKey)) ?? defaults.anthropicAPIKey
        enableSemanticRecall = (try? c.decode(Bool.self, forKey: .enableSemanticRecall)) ?? defaults.enableSemanticRecall
        preserveThreadAcrossMeetings = (try? c.decode(Bool.self, forKey: .preserveThreadAcrossMeetings)) ?? defaults.preserveThreadAcrossMeetings

        if let decodedProfiles = try? c.decode([CoachProfile].self, forKey: .profiles), !decodedProfiles.isEmpty {
            profiles = decodedProfiles
            activeProfileID = (try? c.decode(UUID.self, forKey: .activeProfileID)) ?? decodedProfiles[0].id
            seededDefaultIDs = (try? c.decode(Set<UUID>.self, forKey: .seededDefaultIDs)) ?? []
        } else {
            // Migration: build a single profile from the legacy flat fields.
            let legacyPrompt = (try? c.decode(String.self, forKey: .legacySystemPrompt))
                ?? CoachProfile.salesCoachPrompt
            let migrated = CoachProfile(
                id: CoachProfile.salesCoachID,
                name: "Sales Coach",
                provider: (try? c.decode(String.self, forKey: .legacyProvider)) ?? "anthropic",
                anthropicModel: (try? c.decode(String.self, forKey: .legacyAnthropicModel)) ?? "claude-sonnet-4-6",
                openAIModel: (try? c.decode(String.self, forKey: .legacyOpenAIModel)) ?? "gpt-5.4-mini",
                chatGPTModel: (try? c.decode(String.self, forKey: .legacyChatGPTModel)) ?? "gpt-5.4-mini",
                systemPrompt: legacyPrompt,
                agentInstructions: (try? c.decode(String.self, forKey: .legacyAgentInstructions)) ?? "",
                workingMemoryTemplate: CoachProfile.salesWorkingMemory,
                proactiveEnabled: (try? c.decode(Bool.self, forKey: .legacyProactiveEnabled)) ?? true,
                minCharsBeforeTrigger: (try? c.decode(Int.self, forKey: .legacyMinCharsBeforeTrigger)) ?? 200
            )
            profiles = [migrated]
            activeProfileID = migrated.id
            // Migrated users only had Sales Coach on disk — they've never seen
            // any of the newer bundled personas. Leave seededDefaultIDs empty
            // so the auto-seed pass below fills them in.
            seededDefaultIDs = []
        }

        // Auto-seed any bundled default profile the user hasn't been offered
        // yet. Deleted defaults stay deleted because their ID stays in
        // seededDefaultIDs even after removal.
        var currentIDs = Set(profiles.map(\.id))
        for bundled in CoachProfile.defaults where !seededDefaultIDs.contains(bundled.id) {
            if !currentIDs.contains(bundled.id) {
                profiles.append(bundled)
                currentIDs.insert(bundled.id)
            }
            seededDefaultIDs.insert(bundled.id)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(anthropicAPIKey, forKey: .anthropicAPIKey)
        try c.encode(enableSemanticRecall, forKey: .enableSemanticRecall)
        try c.encode(preserveThreadAcrossMeetings, forKey: .preserveThreadAcrossMeetings)
        try c.encode(profiles, forKey: .profiles)
        try c.encode(activeProfileID, forKey: .activeProfileID)
        try c.encode(seededDefaultIDs, forKey: .seededDefaultIDs)
    }
}

struct AppConfig: Codable {
    var dictationHotkey: HotkeyConfig = .default
    var sttBackend: String = BackendOption.whisper.backend
    var sttModel: String = BackendOption.whisper.model
    var meetingTranscriptionBackend: String = BackendOption.whisper.backend
    var meetingTranscriptionModel: String = BackendOption.whisper.model
    var meetingSummaryBackend: String = MeetingSummaryBackendOption.openAI.backend
    var defaultMeetingTemplateID: String = MeetingTemplates.autoID
    var whisperModel: String = BackendOption.whisper.model
    var idleTimeout: Double = 120
    var autoRecordMeetings: Bool = false
    var showMeetingDetectionNotification: Bool = true
    var meetingRecordingSavePolicy: MeetingRecordingSavePolicy = .never
    var darkMode: Bool = true
    var enableDoubleTapDictation: Bool = true
    var launchAtLogin: Bool = false
    var openDashboardOnLaunch: Bool = true
    var showFloatingIndicator: Bool = true
    var indicatorAnchor: IndicatorAnchor = .midTrailing
    var dashboardWindowFrame: WindowFrame? = nil
    var indicatorOrigin: CGPointCodable? = nil
    var openAIAPIKey: String = ""
    var openRouterAPIKey: String = ""
    var openAIModel: String = ""
    var openRouterModel: String = ""
    var chatGPTModel: String = ""
    var summaryModel: String = ""
    var meetingSummaryModel: String = ""
    var hasCompletedOnboarding: Bool = false
    var userName: String = ""
    var customMeetingTemplates: [CustomMeetingTemplate] = []
    var customWords: [CustomWord] = [
        CustomWord(word: "muesli", replacement: "muesli"),
    ]
    var folderOrder: [Int64] = []
    var soundEnabled: Bool = true
    var recordingColorHex: String = "1e1e2e"   // Catppuccin Mocha base, without #
    var menuBarIcon: String = "muesli"
    var showNextMeetingInMenuBar: Bool = true
    var maraudersMapUnlocked: Bool = false
    var maraudersMapAudioClip: String = "bbc_world_news"
    var maraudersMapCustomAudioPath: String?
    var hiddenCalendarEventIDs: [String] = []
    var enablePostProcessor: Bool = false
    var activePostProcessorId: String = PostProcessorOption.defaultOption.id
    var postProcessorSystemPrompt: String = PostProcessorOption.defaultSystemPrompt
    var enableScreenContext: Bool = false
    var useCoreAudioTap: Bool = true
    var liveCoach: LiveCoachSettings = LiveCoachSettings()

    enum CodingKeys: String, CodingKey {
        case dictationHotkey = "dictation_hotkey"
        case sttBackend = "stt_backend"
        case sttModel = "stt_model"
        case meetingTranscriptionBackend = "meeting_transcription_backend"
        case meetingTranscriptionModel = "meeting_transcription_model"
        case meetingSummaryBackend = "meeting_summary_backend"
        case defaultMeetingTemplateID = "default_meeting_template_id"
        case whisperModel = "whisper_model"
        case idleTimeout = "idle_timeout"
        case autoRecordMeetings = "auto_record_meetings"
        case showMeetingDetectionNotification = "show_meeting_detection_notification"
        case meetingRecordingSavePolicy = "meeting_recording_save_policy"
        case darkMode = "dark_mode"
        case enableDoubleTapDictation = "enable_double_tap_dictation"
        case launchAtLogin = "launch_at_login"
        case openDashboardOnLaunch = "open_dashboard_on_launch"
        case showFloatingIndicator = "show_floating_indicator"
        case indicatorAnchor = "indicator_anchor"
        case dashboardWindowFrame = "dashboard_window_frame"
        case indicatorOrigin = "indicator_origin"
        case openAIAPIKey = "openai_api_key"
        case openRouterAPIKey = "openrouter_api_key"
        case openAIModel = "openai_model"
        case openRouterModel = "openrouter_model"
        case chatGPTModel = "chatgpt_model"
        case summaryModel = "summary_model"
        case meetingSummaryModel = "meeting_summary_model"
        case hasCompletedOnboarding = "has_completed_onboarding"
        case userName = "user_name"
        case customMeetingTemplates = "custom_meeting_templates"
        case customWords = "custom_words"
        case folderOrder = "folder_order"
        case soundEnabled = "sound_enabled"
        case recordingColorHex = "recording_color_hex"
        case menuBarIcon = "menu_bar_icon"
        case showNextMeetingInMenuBar = "show_next_meeting_in_menu_bar"
        case maraudersMapUnlocked = "marauders_map_unlocked"
        case maraudersMapAudioClip = "marauders_map_audio_clip"
        case maraudersMapCustomAudioPath = "marauders_map_custom_audio_path"
        case hiddenCalendarEventIDs = "hidden_calendar_event_ids"
        case enablePostProcessor = "enable_post_processor"
        case activePostProcessorId = "active_post_processor_id"
        case postProcessorSystemPrompt = "post_processor_system_prompt"
        case enableScreenContext = "enable_screen_context"
        case useCoreAudioTap = "use_core_audio_tap"
        case liveCoach = "live_coach"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        dictationHotkey = (try? c.decode(HotkeyConfig.self, forKey: .dictationHotkey)) ?? defaults.dictationHotkey
        sttBackend = (try? c.decode(String.self, forKey: .sttBackend)) ?? defaults.sttBackend
        sttModel = (try? c.decode(String.self, forKey: .sttModel)) ?? defaults.sttModel
        meetingTranscriptionBackend = (try? c.decode(String.self, forKey: .meetingTranscriptionBackend)) ?? sttBackend
        meetingTranscriptionModel = (try? c.decode(String.self, forKey: .meetingTranscriptionModel)) ?? sttModel
        meetingSummaryBackend = (try? c.decode(String.self, forKey: .meetingSummaryBackend)) ?? defaults.meetingSummaryBackend
        defaultMeetingTemplateID = (try? c.decode(String.self, forKey: .defaultMeetingTemplateID)) ?? defaults.defaultMeetingTemplateID
        whisperModel = (try? c.decode(String.self, forKey: .whisperModel)) ?? defaults.whisperModel
        idleTimeout = (try? c.decode(Double.self, forKey: .idleTimeout)) ?? defaults.idleTimeout
        autoRecordMeetings = (try? c.decode(Bool.self, forKey: .autoRecordMeetings)) ?? defaults.autoRecordMeetings
        showMeetingDetectionNotification = (try? c.decode(Bool.self, forKey: .showMeetingDetectionNotification)) ?? defaults.showMeetingDetectionNotification
        meetingRecordingSavePolicy = (try? c.decode(MeetingRecordingSavePolicy.self, forKey: .meetingRecordingSavePolicy)) ?? defaults.meetingRecordingSavePolicy
        darkMode = (try? c.decode(Bool.self, forKey: .darkMode)) ?? defaults.darkMode
        enableDoubleTapDictation = (try? c.decode(Bool.self, forKey: .enableDoubleTapDictation)) ?? defaults.enableDoubleTapDictation
        launchAtLogin = (try? c.decode(Bool.self, forKey: .launchAtLogin)) ?? defaults.launchAtLogin
        openDashboardOnLaunch = (try? c.decode(Bool.self, forKey: .openDashboardOnLaunch)) ?? defaults.openDashboardOnLaunch
        showFloatingIndicator = (try? c.decode(Bool.self, forKey: .showFloatingIndicator)) ?? defaults.showFloatingIndicator
        indicatorAnchor = (try? c.decode(IndicatorAnchor.self, forKey: .indicatorAnchor))
            ?? ((try? c.decodeIfPresent(CGPointCodable.self, forKey: .indicatorOrigin)) != nil ? .custom : .midTrailing)
        dashboardWindowFrame = try? c.decode(WindowFrame.self, forKey: .dashboardWindowFrame)
        indicatorOrigin = try? c.decode(CGPointCodable.self, forKey: .indicatorOrigin)
        openAIAPIKey = (try? c.decode(String.self, forKey: .openAIAPIKey)) ?? defaults.openAIAPIKey
        openRouterAPIKey = (try? c.decode(String.self, forKey: .openRouterAPIKey)) ?? defaults.openRouterAPIKey
        openAIModel = (try? c.decode(String.self, forKey: .openAIModel)) ?? defaults.openAIModel
        openRouterModel = (try? c.decode(String.self, forKey: .openRouterModel)) ?? defaults.openRouterModel
        chatGPTModel = (try? c.decode(String.self, forKey: .chatGPTModel)) ?? defaults.chatGPTModel
        summaryModel = (try? c.decode(String.self, forKey: .summaryModel)) ?? defaults.summaryModel
        meetingSummaryModel = (try? c.decode(String.self, forKey: .meetingSummaryModel)) ?? defaults.meetingSummaryModel
        hasCompletedOnboarding = (try? c.decode(Bool.self, forKey: .hasCompletedOnboarding)) ?? defaults.hasCompletedOnboarding
        userName = (try? c.decode(String.self, forKey: .userName)) ?? defaults.userName
        customMeetingTemplates = (try? c.decode([CustomMeetingTemplate].self, forKey: .customMeetingTemplates)) ?? defaults.customMeetingTemplates
        customWords = (try? c.decode([CustomWord].self, forKey: .customWords)) ?? defaults.customWords
        folderOrder = (try? c.decode([Int64].self, forKey: .folderOrder)) ?? defaults.folderOrder
        soundEnabled = (try? c.decode(Bool.self, forKey: .soundEnabled)) ?? defaults.soundEnabled
        recordingColorHex = (try? c.decode(String.self, forKey: .recordingColorHex)) ?? defaults.recordingColorHex
        menuBarIcon = (try? c.decode(String.self, forKey: .menuBarIcon)) ?? defaults.menuBarIcon
        showNextMeetingInMenuBar = (try? c.decode(Bool.self, forKey: .showNextMeetingInMenuBar)) ?? defaults.showNextMeetingInMenuBar
        maraudersMapUnlocked = (try? c.decode(Bool.self, forKey: .maraudersMapUnlocked)) ?? defaults.maraudersMapUnlocked
        maraudersMapAudioClip = (try? c.decode(String.self, forKey: .maraudersMapAudioClip)) ?? defaults.maraudersMapAudioClip
        maraudersMapCustomAudioPath = try? c.decode(String.self, forKey: .maraudersMapCustomAudioPath)
        hiddenCalendarEventIDs = (try? c.decode([String].self, forKey: .hiddenCalendarEventIDs)) ?? defaults.hiddenCalendarEventIDs
        enablePostProcessor = (try? c.decode(Bool.self, forKey: .enablePostProcessor)) ?? defaults.enablePostProcessor
        activePostProcessorId = (try? c.decode(String.self, forKey: .activePostProcessorId)) ?? defaults.activePostProcessorId
        postProcessorSystemPrompt = (try? c.decode(String.self, forKey: .postProcessorSystemPrompt)) ?? defaults.postProcessorSystemPrompt
        enableScreenContext = (try? c.decode(Bool.self, forKey: .enableScreenContext)) ?? defaults.enableScreenContext
        useCoreAudioTap = (try? c.decode(Bool.self, forKey: .useCoreAudioTap)) ?? defaults.useCoreAudioTap
        liveCoach = (try? c.decode(LiveCoachSettings.self, forKey: .liveCoach)) ?? defaults.liveCoach
    }
}

struct WindowFrame: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct CGPointCodable: Codable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(from decoder: Decoder) throws {
        if var arrayContainer = try? decoder.unkeyedContainer() {
            let x = try arrayContainer.decode(Double.self)
            let y = try arrayContainer.decode(Double.self)
            self.init(x: x, y: y)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            x: try container.decode(Double.self, forKey: .x),
            y: try container.decode(Double.self, forKey: .y)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
    }

    enum CodingKeys: String, CodingKey {
        case x, y
    }
}

enum DictationState: String {
    case idle
    case preparing
    case recording
    case transcribing
}
