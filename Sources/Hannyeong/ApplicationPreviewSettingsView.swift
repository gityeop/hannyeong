import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PreviewLanguageToggle: View {
    @Binding var english: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button { english = false } label: { Text("한글").frame(width: 48) }
                .buttonStyle(SettingsSegmentButtonStyle(selected: !english))
                .focusable(false)
                .accessibilityAddTraits(!english ? .isSelected : [])
            Button { english = true } label: { Text("영어").frame(width: 48) }
                .buttonStyle(SettingsSegmentButtonStyle(selected: english))
                .focusable(false)
                .accessibilityAddTraits(english ? .isSelected : [])
        }
        .padding(3)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

struct AlternatePreviewSizePicker: View {
    @Binding var size: CompositionPreviewSettings.AlternateSize

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CompositionPreviewSettings.AlternateSize.allCases, id: \.self) { item in
                Button { size = item } label: { Text(item.title).frame(width: 48) }
                    .buttonStyle(SettingsSegmentButtonStyle(selected: size == item))
                    .focusable(false)
                    .accessibilityAddTraits(size == item ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .accessibilityIdentifier("alternate-preview-size")
    }
}

@MainActor
struct ApplicationPreviewSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var applications = CompositionPreviewSettings.applications(in: .standard)
    @State private var selectionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("앱별 기본 표시").font(.system(size: 22, weight: .bold))
            Text("추가한 앱에만 적용됩니다. 목록에서 지우면 공통 설정을 따릅니다.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            SettingsCard {
                if applications.isEmpty {
                    Text("앱을 추가해 한글·영어 표시를 따로 정해보세요.")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(applications.keys.sorted(), id: \.self) { bundleID in
                                HStack(spacing: 12) {
                                    applicationLabel(bundleID)
                                    Spacer()
                                    PreviewLanguageToggle(english: Binding(
                                        get: { applications[bundleID]! },
                                        set: { set($0, for: bundleID) }))
                                    Button { set(nil, for: bundleID) } label: {
                                        Image(systemName: "minus").frame(width: 12)
                                    }
                                    .buttonStyle(SettingsSmallButtonStyle())
                                    .focusable(false)
                                    .accessibilityLabel("앱별 설정 삭제")
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .frame(height: 240)
                }
            }
            if let selectionError {
                Text(selectionError).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HStack {
                Button("앱 추가…", action: addApplication)
                    .buttonStyle(SettingsSmallButtonStyle())
                    .focusable(false)
                Spacer()
                Button("완료") { dismiss() }
                    .buttonStyle(SettingsSmallButtonStyle(prominent: true))
                    .focusable(false)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 660)
        .background(.regularMaterial)
        .tint(SettingsAppearance.accent)
    }

    @ViewBuilder
    private func applicationLabel(_ bundleID: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().scaledToFit().frame(width: 28, height: 28)
            Text(FileManager.default.displayName(atPath: url.path))
                .font(.system(size: 14, weight: .medium)).lineLimit(1)
        } else {
            Text(bundleID).font(.system(size: 14)).lineLimit(1)
        }
    }

    private func set(_ english: Bool?, for bundleID: String) {
        CompositionPreviewSettings.set(english, for: bundleID, in: .standard)
        applications = CompositionPreviewSettings.applications(in: .standard)
    }

    private func addApplication() {
        selectionError = nil
        let panel = NSOpenPanel()
        panel.title = "기본 표시를 설정할 앱 선택"
        panel.prompt = "추가"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
                AppSupport.shared.reportConfigurationError(NSError(domain: "HannyeongApplicationPreview", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Selected application has no bundle identifier"]))
                selectionError = "앱 정보를 읽지 못했습니다."
                return
            }
            if applications[bundleID] == nil {
                set(UserDefaults.standard.bool(forKey: CompositionPreviewSettings.defaultKey), for: bundleID)
            }
        }
    }
}
