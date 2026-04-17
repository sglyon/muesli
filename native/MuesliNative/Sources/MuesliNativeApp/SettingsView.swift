import SwiftUI
import MuesliCore

struct SettingsView: View {
    let appState: AppState
    let controller: MuesliController

    @State private var chatGPTSignInError: String?
    @State private var isSigningInChatGPT = false

    // Uniform width for all right-side controls
    private let controlWidth: CGFloat = 220

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                Text("Settings")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)

                settingsSection("General") {
                    settingsRow("Launch at login") {
                        settingsSwitch(isOn: appState.config.launchAtLogin) { newValue in
                            controller.updateConfig { $0.launchAtLogin = newValue }
                        }
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Open dashboard on launch") {
                        settingsSwitch(isOn: appState.config.openDashboardOnLaunch) { newValue in
                            controller.updateConfig { $0.openDashboardOnLaunch = newValue }
                        }
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Dark mode") {
                        settingsSwitch(isOn: appState.config.darkMode) { newValue in
                            controller.updateConfig { $0.darkMode = newValue }
                        }
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Show floating indicator") {
                        settingsSwitch(isOn: appState.config.showFloatingIndicator) { newValue in
                            controller.updateConfig { $0.showFloatingIndicator = newValue }
                            controller.refreshIndicatorVisibility()
                        }
                    }
                }

                settingsSection("Transcription") {
                    settingsRow("Backend") {
                        settingsMenu(
                            selection: appState.selectedBackend.label,
                            options: BackendOption.all.map(\.label)
                        ) { label in
                            if let option = BackendOption.all.first(where: { $0.label == label }) {
                                controller.selectBackend(option)
                            }
                        }
                    }
                }

                settingsSection("Meetings") {
                    settingsRow("Summary backend") {
                        settingsMenu(
                            selection: appState.selectedMeetingSummaryBackend.label,
                            options: MeetingSummaryBackendOption.all.map(\.label)
                        ) { label in
                            if let option = MeetingSummaryBackendOption.all.first(where: { $0.label == label }) {
                                controller.selectMeetingSummaryBackend(option)
                            }
                        }
                    }
                    Divider().background(MuesliTheme.surfaceBorder)

                    if appState.selectedMeetingSummaryBackend == .chatGPT {
                        settingsRow("Account") {
                            if appState.isChatGPTAuthenticated {
                                Button {
                                    controller.signOutChatGPT()
                                } label: {
                                    HStack(spacing: 5) {
                                        OpenAILogoShape()
                                            .fill(.white)
                                            .frame(width: 10, height: 10)
                                        Text("Signed in · Sign Out")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(MuesliTheme.success)
                                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                                }
                                .buttonStyle(.plain)
                            } else if isSigningInChatGPT {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Signing in...")
                                        .font(.system(size: 11))
                                        .foregroundStyle(MuesliTheme.textSecondary)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    Button {
                                        isSigningInChatGPT = true
                                        chatGPTSignInError = nil
                                        Task {
                                            let error = await controller.signInWithChatGPT()
                                            isSigningInChatGPT = false
                                            chatGPTSignInError = error
                                        }
                                    } label: {
                                        HStack(spacing: 5) {
                                            OpenAILogoShape()
                                                .fill(.white)
                                                .frame(width: 10, height: 10)
                                            Text("Sign in with ChatGPT")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(MuesliTheme.accent)
                                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                                    }
                                    .buttonStyle(.plain)

                                    if let chatGPTSignInError {
                                        Text(chatGPTSignInError)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.red)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }
                        Divider().background(MuesliTheme.surfaceBorder)
                        settingsRow("Model") {
                            settingsModelMenu(
                                currentModel: appState.config.chatGPTModel,
                                presets: SummaryModelPreset.chatGPTModels
                            ) { val in controller.updateConfig { $0.chatGPTModel = val } }
                        }
                    } else if appState.selectedMeetingSummaryBackend == .openAI {
                        settingsRow("API Key") {
                            PastableSecureField(
                                text: appState.config.openAIAPIKey,
                                placeholder: "sk-...",
                                onChange: { val in controller.updateConfig { $0.openAIAPIKey = val } }
                            )
                            .frame(width: controlWidth, height: 22)
                        }
                        Divider().background(MuesliTheme.surfaceBorder)
                        settingsRow("Model") {
                            settingsModelMenu(
                                currentModel: appState.config.openAIModel,
                                presets: SummaryModelPreset.openAIModels
                            ) { val in controller.updateConfig { $0.openAIModel = val } }
                        }
                        keyStatusRow(key: appState.config.openAIAPIKey)
                    } else {
                        settingsRow("API Key") {
                            PastableSecureField(
                                text: appState.config.openRouterAPIKey,
                                placeholder: "sk-or-...",
                                onChange: { val in controller.updateConfig { $0.openRouterAPIKey = val } }
                            )
                            .frame(width: controlWidth, height: 22)
                        }
                        Divider().background(MuesliTheme.surfaceBorder)
                        settingsRow("Model") {
                            settingsModelMenu(
                                currentModel: appState.config.openRouterModel,
                                presets: SummaryModelPreset.openRouterModels
                            ) { val in controller.updateConfig { $0.openRouterModel = val } }
                        }
                        keyStatusRow(key: appState.config.openRouterAPIKey)
                    }

                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Auto-record calendar meetings") {
                        settingsSwitch(isOn: appState.config.autoRecordMeetings) { newValue in
                            controller.updateConfig { $0.autoRecordMeetings = newValue }
                        }
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Notify when meeting detected") {
                        settingsSwitch(isOn: appState.config.showMeetingDetectionNotification) { newValue in
                            controller.updateConfig { $0.showMeetingDetectionNotification = newValue }
                        }
                    }
                }

                liveCoachSection

                settingsSection("Data") {
                    HStack(spacing: MuesliTheme.spacing12) {
                        actionButton("Clear dictation history", role: .destructive) {
                            controller.clearDictationHistory()
                        }
                        actionButton("Clear meeting history", role: .destructive) {
                            controller.clearMeetingHistory()
                        }
                        actionButton("Reset coach memory", role: .destructive) {
                            controller.resetCoachMemory()
                        }
                    }
                }
            }
            .padding(MuesliTheme.spacing32)
        }
        .background(MuesliTheme.backgroundBase)
    }

    // MARK: - Live Coach section

    private struct CoachProviderOption {
        let backend: String
        let label: String
        static let anthropic = CoachProviderOption(backend: "anthropic", label: "Anthropic")
        static let openAI = CoachProviderOption(backend: "openai", label: "OpenAI")
        static let chatGPT = CoachProviderOption(backend: "chatgpt", label: "ChatGPT (OAuth)")
        static let all: [CoachProviderOption] = [.anthropic, .openAI, .chatGPT]
    }

    private var liveCoachSection: some View {
        let coach = appState.config.liveCoach
        return settingsSection("Live Coach") {
            settingsRow("Enable live coach during meetings") {
                settingsSwitch(isOn: coach.enabled) { newValue in
                    controller.updateConfig { $0.liveCoach.enabled = newValue }
                }
            }

            if coach.enabled {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Anthropic API Key") {
                    PastableSecureField(
                        text: coach.anthropicAPIKey,
                        placeholder: "sk-ant-...",
                        onChange: { val in controller.updateConfig { $0.liveCoach.anthropicAPIKey = val } }
                    )
                    .frame(width: controlWidth, height: 22)
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Default profile") {
                    settingsMenu(
                        selection: coach.activeProfile.name,
                        options: coach.profiles.map(\.name)
                    ) { label in
                        if let chosen = coach.profiles.first(where: { $0.name == label }) {
                            controller.updateConfig { $0.liveCoach.activeProfileID = chosen.id }
                        }
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Enable semantic recall across meetings") {
                    settingsSwitch(isOn: coach.enableSemanticRecall) { newValue in
                        controller.updateConfig { $0.liveCoach.enableSemanticRecall = newValue }
                    }
                }
                if coach.enableSemanticRecall, appState.config.openAIAPIKey.isEmpty {
                    HStack {
                        Spacer()
                        Text("Add an OpenAI API key under Meetings → OpenAI to enable semantic recall — it's used only for embeddings.")
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Preserve coach memory across meetings") {
                    settingsSwitch(isOn: coach.preserveThreadAcrossMeetings) { newValue in
                        controller.updateConfig { $0.liveCoach.preserveThreadAcrossMeetings = newValue }
                    }
                }

                Divider().background(MuesliTheme.surfaceBorder)
                profileManager(coach: coach)
            }
        }
    }

    @ViewBuilder
    private func profileManager(coach: LiveCoachSettings) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack {
                Text("Profiles")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Spacer()
                actionButton("Add profile") {
                    let copy = CoachProfile(
                        name: "New Profile",
                        systemPrompt: "You are a meeting coach. Reply with 1-3 short, actionable observations when you receive a <transcript_update>; answer directly when you receive a <user_message>. Plain text, under 120 words."
                    )
                    controller.updateConfig { $0.liveCoach.profiles.append(copy) }
                }
            }
            ForEach(coach.profiles) { profile in
                profileRow(profile, isOnly: coach.profiles.count == 1)
                    .padding(MuesliTheme.spacing8)
                    .background(MuesliTheme.backgroundBase)
                    .cornerRadius(MuesliTheme.cornerSmall)
            }
        }
        .padding(.top, MuesliTheme.spacing8)
    }

    @ViewBuilder
    private func profileRow(_ profile: CoachProfile, isOnly: Bool) -> some View {
        let provider = CoachProviderOption.all.first(where: { $0.backend == profile.provider }) ?? .anthropic
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack {
                TextField("Profile name", text: Binding(
                    get: { profile.name },
                    set: { val in updateProfile(profile.id) { $0.name = val } }
                ))
                .textFieldStyle(.roundedBorder)
                .font(MuesliTheme.body())
                Spacer()
                if !isOnly {
                    Button(role: .destructive) {
                        controller.updateConfig { cfg in
                            cfg.liveCoach.profiles.removeAll { $0.id == profile.id }
                            if cfg.liveCoach.activeProfileID == profile.id, let first = cfg.liveCoach.profiles.first {
                                cfg.liveCoach.activeProfileID = first.id
                            }
                        }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: MuesliTheme.spacing12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Provider").font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textTertiary)
                    settingsMenu(
                        selection: provider.label,
                        options: CoachProviderOption.all.map(\.label)
                    ) { label in
                        if let opt = CoachProviderOption.all.first(where: { $0.label == label }) {
                            updateProfile(profile.id) { $0.provider = opt.backend }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model").font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textTertiary)
                    let modelBinding = Binding(
                        get: { profile.activeModel },
                        set: { val in
                            updateProfile(profile.id) { p in
                                switch p.provider {
                                case "anthropic": p.anthropicModel = val
                                case "openai": p.openAIModel = val
                                case "chatgpt": p.chatGPTModel = val
                                default: break
                                }
                            }
                        }
                    )
                    TextField("model id", text: modelBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: controlWidth)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("System prompt").font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textTertiary)
                TextEditor(text: Binding(
                    get: { profile.systemPrompt },
                    set: { val in updateProfile(profile.id) { $0.systemPrompt = val } }
                ))
                .font(MuesliTheme.body())
                .frame(minHeight: 80, maxHeight: 160)
                .background(MuesliTheme.backgroundRaised)
                .cornerRadius(6)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Working memory template").font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textTertiary)
                TextEditor(text: Binding(
                    get: { profile.workingMemoryTemplate },
                    set: { val in updateProfile(profile.id) { $0.workingMemoryTemplate = val } }
                ))
                .font(MuesliTheme.body())
                .frame(minHeight: 60, maxHeight: 140)
                .background(MuesliTheme.backgroundRaised)
                .cornerRadius(6)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Agent instructions (optional)").font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textTertiary)
                TextEditor(text: Binding(
                    get: { profile.agentInstructions },
                    set: { val in updateProfile(profile.id) { $0.agentInstructions = val } }
                ))
                .font(MuesliTheme.body())
                .frame(minHeight: 40, maxHeight: 100)
                .background(MuesliTheme.backgroundRaised)
                .cornerRadius(6)
            }

            HStack {
                Toggle("Proactive commentary", isOn: Binding(
                    get: { profile.proactiveEnabled },
                    set: { val in updateProfile(profile.id) { $0.proactiveEnabled = val } }
                ))
                .toggleStyle(.switch)
                .tint(MuesliTheme.accent)
                Spacer()
                Stepper(
                    value: Binding(
                        get: { profile.minCharsBeforeTrigger },
                        set: { val in updateProfile(profile.id) { $0.minCharsBeforeTrigger = val } }
                    ),
                    in: 50...2000, step: 50
                ) {
                    Text("trigger after \(profile.minCharsBeforeTrigger) chars")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func updateProfile(_ id: UUID, _ mutate: @escaping (inout CoachProfile) -> Void) {
        controller.updateConfig { cfg in
            if let idx = cfg.liveCoach.profiles.firstIndex(where: { $0.id == id }) {
                mutate(&cfg.liveCoach.profiles[idx])
            }
        }
    }

    @ViewBuilder
    private func settingsTextField(value: String, placeholder: String, onChange: @escaping (String) -> Void) -> some View {
        TextField(placeholder, text: Binding(get: { value }, set: { onChange($0) }))
            .textFieldStyle(.roundedBorder)
            .frame(width: controlWidth)
    }

    // MARK: - Layout Primitives

    @ViewBuilder
    private func settingsSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MuesliTheme.textTertiary)
                .textCase(.uppercase)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(MuesliTheme.spacing16)
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
    }

    /// Standardized row: label on left, control on right, consistent 36pt height
    @ViewBuilder
    private func settingsRow(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
            Spacer()
            control()
        }
        .frame(minHeight: 32)
    }

    // MARK: - Controls

    @ViewBuilder
    private func settingsSwitch(isOn: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        Toggle("", isOn: Binding(get: { isOn }, set: { onChange($0) }))
            .toggleStyle(.switch)
            .tint(MuesliTheme.accent)
            .labelsHidden()
    }

    @ViewBuilder
    private func settingsMenu(selection: String, options: [String], onChange: @escaping (String) -> Void) -> some View {
        Picker("", selection: Binding(get: { selection }, set: { onChange($0) })) {
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.menu)
        .frame(width: controlWidth)
    }

    @ViewBuilder
    private func settingsModelMenu(currentModel: String, presets: [SummaryModelPreset], onChange: @escaping (String) -> Void) -> some View {
        Picker("", selection: Binding(
            get: { currentModel.isEmpty ? (presets.first?.id ?? "") : currentModel },
            set: { onChange($0 == presets.first?.id ? "" : $0) }
        )) {
            ForEach(presets, id: \.id) { Text($0.label).tag($0.id) }
        }
        .pickerStyle(.menu)
        .frame(width: controlWidth)
    }

    @ViewBuilder
    private func keyStatusRow(key: String) -> some View {
        HStack(spacing: 6) {
            Spacer()
            Circle()
                .fill(key.isEmpty ? MuesliTheme.textTertiary : MuesliTheme.success)
                .frame(width: 6, height: 6)
            Text(key.isEmpty ? "No API key configured" : "Key configured")
                .font(.system(size: 11))
                .foregroundStyle(key.isEmpty ? MuesliTheme.textTertiary : MuesliTheme.success)
        }
        .frame(minHeight: 20)
    }

    @ViewBuilder
    private func actionButton(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        let isDestructive = role == .destructive
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isDestructive ? MuesliTheme.recording : MuesliTheme.textPrimary)
                .padding(.horizontal, MuesliTheme.spacing16)
                .padding(.vertical, MuesliTheme.spacing8)
                .background(isDestructive ? MuesliTheme.recording.opacity(0.1) : MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(
                            isDestructive ? MuesliTheme.recording.opacity(0.2) : MuesliTheme.surfaceBorder,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pastable Secure Field (NSViewRepresentable)

/// NSSecureTextField subclass that handles Cmd+V/C/X/A without needing a standard Edit menu.
/// Required because the app runs as .accessory (no menu bar), so key equivalents
/// don't route to text fields by default.
class EditableNSSecureTextField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "v":
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
            case "c":
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            case "x":
                if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
            case "a":
                if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) { return true }
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// A text field that supports Cmd+V paste and masks the value when not focused.
struct PastableSecureField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let onChange: (String) -> Void

    func makeNSView(context: Context) -> EditableNSSecureTextField {
        let field = EditableNSSecureTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ nsView: EditableNSSecureTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        let onChange: (String) -> Void

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            onChange(field.stringValue)
        }
    }
}
