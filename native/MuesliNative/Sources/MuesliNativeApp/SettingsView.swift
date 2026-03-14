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

                    settingsToggle(
                        "Auto-record calendar meetings",
                        isOn: appState.config.autoRecordMeetings
                    ) { newValue in
                        controller.updateConfig { $0.autoRecordMeetings = newValue }
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
