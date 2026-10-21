import Sparkle
import SwiftUI

@MainActor
struct UpdateSettingsView: View {
    @ObservedObject private var updates: AppUpdater
    @State private var automaticChecks: Bool
    @State private var automaticDownloads: Bool

    init(updates: AppUpdater) {
        self.updates = updates
        _automaticChecks = State(initialValue: updates.controller.updater.automaticallyChecksForUpdates)
        _automaticDownloads = State(initialValue: updates.controller.updater.automaticallyDownloadsUpdates)
    }

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("업데이트").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button("업데이트 확인…") { updates.checkForUpdates() }
                        .buttonStyle(SettingsSmallButtonStyle())
                        .disabled(!updates.canCheckForUpdates)
                        .accessibilityIdentifier("check-for-updates")
                }
                Toggle("업데이트 자동 확인", isOn: $automaticChecks)
                    .onChange(of: automaticChecks) { value in
                        updates.controller.updater.automaticallyChecksForUpdates = value
                    }
                Toggle("업데이트 자동 다운로드 및 설치", isOn: $automaticDownloads)
                    .disabled(!automaticChecks)
                    .onChange(of: automaticDownloads) { value in
                        updates.controller.updater.automaticallyDownloadsUpdates = value
                    }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }
}
