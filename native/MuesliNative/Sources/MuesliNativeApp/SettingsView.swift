import SwiftUI

struct SettingsView: View {
    let appState: AppState
    let controller: MuesliController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                Text("Settings")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)

                settingsSection("General") {
                    settingsToggle(
                        "Launch at login",
                        isOn: appState.config.launchAtLogin
                    ) { newValue in
                        controller.updateConfig { $0.launchAtLogin = newValue }
                    }

                    settingsToggle(
                        "Open dashboard on launch",
                        isOn: appState.config.openDashboardOnLaunch
                    ) { newValue in
                        controller.updateConfig { $0.openDashboardOnLaunch = newValue }
                    }

                    settingsToggle(
                        "Dark mode",
                        isOn: appState.config.darkMode
                    ) { newValue in
                        controller.updateConfig { $0.darkMode = newValue }
                    }

                    settingsToggle(
                        "Show floating indicator",
                        isOn: appState.config.showFloatingIndicator
                    ) { newValue in
                        controller.updateConfig { $0.showFloatingIndicator = newValue }
                        controller.refreshIndicatorVisibility()
                    }
                }

                settingsSection("Transcription") {
                    settingsPicker(
                        "Backend",
                        selection: appState.selectedBackend.label,
                        options: BackendOption.all.map(\.label)
                    ) { label in
                        if let option = BackendOption.all.first(where: { $0.label == label }) {
                            controller.selectBackend(option)
                        }
                    }
                }

                settingsSection("Meetings") {
                    settingsPicker(
                        "Summary backend",
                        selection: appState.selectedMeetingSummaryBackend.label,
                        options: MeetingSummaryBackendOption.all.map(\.label)
                    ) { label in
                        if let option = MeetingSummaryBackendOption.all.first(where: { $0.label == label }) {
                            controller.selectMeetingSummaryBackend(option)
                        }
                    }

                    if appState.selectedMeetingSummaryBackend == .openAI {
                        settingsSecureField(
                            "API Key",
                            text: appState.config.openAIAPIKey,
                            placeholder: "sk-..."
                        ) { newValue in
                            controller.updateConfig { $0.openAIAPIKey = newValue }
                        }

                        settingsModelPicker(
                            currentModel: appState.config.openAIModel,
                            presets: SummaryModelPreset.openAIModels
                        ) { newValue in
                            controller.updateConfig { $0.openAIModel = newValue }
                        }

                        keyStatus(key: appState.config.openAIAPIKey)
                    } else {
                        settingsSecureField(
                            "API Key",
                            text: appState.config.openRouterAPIKey,
                            placeholder: "sk-or-..."
                        ) { newValue in
                            controller.updateConfig { $0.openRouterAPIKey = newValue }
                        }

                        settingsModelPicker(
                            currentModel: appState.config.openRouterModel,
                            presets: SummaryModelPreset.openRouterModels
                        ) { newValue in
                            controller.updateConfig { $0.openRouterModel = newValue }
                        }

                        keyStatus(key: appState.config.openRouterAPIKey)
                    }

                    settingsToggle(
                        "Auto-record calendar meetings",
                        isOn: appState.config.autoRecordMeetings
                    ) { newValue in
                        controller.updateConfig { $0.autoRecordMeetings = newValue }
                    }

                    settingsToggle(
                        "Notify when meeting app detected",
                        isOn: appState.config.showMeetingDetectionNotification
                    ) { newValue in
                        controller.updateConfig { $0.showMeetingDetectionNotification = newValue }
                    }
                }

                settingsSection("Data") {
                    HStack(spacing: MuesliTheme.spacing12) {
                        destructiveButton("Clear dictation history") {
                            controller.clearDictationHistory()
                        }
                        destructiveButton("Clear meeting history") {
                            controller.clearMeetingHistory()
                        }
                    }
                }
            }
            .padding(MuesliTheme.spacing32)
        }
        .background(MuesliTheme.backgroundBase)
    }

    @ViewBuilder
    private func settingsSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Text(title)
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textSecondary)
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .semibold))

            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
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

    @ViewBuilder
    private func settingsToggle(_ title: String, isOn: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(
            get: { isOn },
            set: { onChange($0) }
        )) {
            Text(title)
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
        }
        .toggleStyle(.switch)
        .tint(MuesliTheme.accent)
    }

    @ViewBuilder
    private func settingsPicker(_ title: String, selection: String, options: [String], onChange: @escaping (String) -> Void) -> some View {
        HStack {
            Text(title)
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
            Spacer()
            Picker("", selection: Binding(
                get: { selection },
                set: { onChange($0) }
            )) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 200)
        }
    }

    @ViewBuilder
    private func settingsSecureField(_ title: String, text: String, placeholder: String, onChange: @escaping (String) -> Void) -> some View {
        HStack {
            Text(title)
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
            Spacer()
            PastableSecureField(text: text, placeholder: placeholder, onChange: onChange)
                .frame(maxWidth: 240, maxHeight: 22)
        }
    }

    @ViewBuilder
    private func settingsModelPicker(currentModel: String, presets: [SummaryModelPreset], onChange: @escaping (String) -> Void) -> some View {
        HStack {
            Text("Model")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
            Spacer()
            Picker("", selection: Binding(
                get: {
                    // If current model matches a preset, select it; otherwise select first (default)
                    if currentModel.isEmpty { return presets.first?.id ?? "" }
                    return currentModel
                },
                set: { newValue in
                    // If selecting the default (first preset), store empty string so MeetingSummaryClient uses its default
                    if newValue == presets.first?.id {
                        onChange("")
                    } else {
                        onChange(newValue)
                    }
                }
            )) {
                ForEach(presets, id: \.id) { preset in
                    Text(preset.label).tag(preset.id)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 240)
        }
    }

    @ViewBuilder
    private func keyStatus(key: String) -> some View {
        HStack(spacing: 6) {
            Spacer()
            Circle()
                .fill(key.isEmpty ? MuesliTheme.textTertiary : MuesliTheme.success)
                .frame(width: 6, height: 6)
            Text(key.isEmpty ? "No API key configured" : "Key configured")
                .font(.system(size: 11))
                .foregroundStyle(key.isEmpty ? MuesliTheme.textTertiary : MuesliTheme.success)
        }
    }

    @ViewBuilder
    private func destructiveButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MuesliTheme.recording)
                .padding(.horizontal, MuesliTheme.spacing16)
                .padding(.vertical, MuesliTheme.spacing8)
                .background(MuesliTheme.recording.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.recording.opacity(0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pastable Secure Field (NSViewRepresentable)

/// A text field that supports Cmd+V paste and masks the value when not focused.
private struct PastableSecureField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let onChange: (String) -> Void

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ nsView: NSSecureTextField, context: Context) {
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
