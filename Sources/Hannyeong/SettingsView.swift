import AppKit
import SwiftUI

@MainActor
struct SettingsView: View {
    private enum Section: String, CaseIterable {
        case general = "일반", corrections = "저장된 교정", information = "정보"
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .corrections: "bookmark"
            case .information: "info.circle"
            }
        }
    }

    let corrections: CorrectionsViewController
    @ObservedObject var windowActivity = SettingsWindowActivity()
    @State private var section = Section.general

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 2) {
                ForEach(Section.allCases, id: \.self) { item in
                    Button { section = item } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 18))
                                .frame(width: 22)
                                .foregroundStyle(section == item ? Color.white : SettingsAppearance.accent)
                            Text(item.rawValue).font(.system(size: 14, weight: .medium))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(section == item ? Color.white : Color.primary)
                        .padding(.horizontal, 10)
                        .frame(height: 40)
                        .background(section == item ? SettingsAppearance.accent : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .accessibilityAddTraits(section == item ? .isSelected : [])
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 42)
            .frame(width: 180)
            .background(.regularMaterial)

            Divider()

            Group {
                switch section {
                case .general: GeneralSettingsView(animationsActive: windowActivity.isVisible)
                case .corrections: CorrectionsSettingsPane(controller: corrections)
                case .information: InformationSettingsView()
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 850, minHeight: 650)
        .background(.regularMaterial)
        .tint(SettingsAppearance.accent)
        .ignoresSafeArea()
    }
}

@MainActor
private struct GeneralSettingsView: View {
    let animationsActive: Bool
    @AppStorage("composition.previewEnglish") private var previewEnglish = false
    @AppStorage(CompositionPreviewSettings.alternateEnabledKey) private var alternatePreviewEnabled = true
    @State private var practiceText = ""
    @State private var commandAction: RightCommandGesture.Action?
    @State private var commandSequence = 0
    @State private var showShortcutGuide = false
    @State private var showApplicationPreviews = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("일반").font(.system(size: 22, weight: .bold))
                SettingsCard {
                    VStack(spacing: 14) {
                        HStack {
                            Text("입력 중 기본 표시").font(.system(size: 14, weight: .medium))
                            Spacer()
                            PreviewLanguageToggle(english: $previewEnglish)
                            Button("앱별 설정…") { showApplicationPreviews = true }
                                .buttonStyle(SettingsSmallButtonStyle())
                                .focusable(false)
                        }
                        Divider()
                        HStack {
                            Text("반대 언어 미리보기").font(.system(size: 14, weight: .medium))
                            Spacer()
                            Toggle("반대 언어 미리보기", isOn: $alternatePreviewEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .focusable(false)
                                .accessibilityIdentifier("alternate-preview-enabled")
                        }
                    }
                }
                SettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("글자 쳐보기").font(.system(size: 16, weight: .semibold))
                        TutorialPracticeField(text: $practiceText,
                                              placeholder: "안녕 hello를 입력해보세요",
                                              accessibilityLabel: "글자 쳐보기",
                                              onBeginEditing: {},
                                              onCommandAction: { action in
                                                  commandAction = action
                                                  commandSequence += 1
                                              })
                            .frame(height: 44)
                            .padding(.horizontal, 14)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
                SettingsCard {
                    CommandShortcutDemos(action: commandAction, actionSequence: commandSequence,
                                         isActive: animationsActive)
                        .padding(.vertical, 12)
                }
                HStack {
                    Spacer()
                    Button("한영키 설정 안내") { showShortcutGuide = true }
                        .buttonStyle(SettingsSmallButtonStyle())
                        .focusable(false)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showShortcutGuide) { ShortcutSetupGuide() }
        .sheet(isPresented: $showApplicationPreviews) { ApplicationPreviewSettingsView() }
    }
}

@MainActor
private struct InformationSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("정보").font(.system(size: 22, weight: .bold))
            SettingsCard {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().scaledToFit().frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("한녕").font(.system(size: 20, weight: .semibold))
                        Text("한영키 없이, 그냥 타이핑")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                        Text("버전 " + (Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! String))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            SettingsCard {
                HStack(spacing: 16) {
                    Text("앞 단어 교정을 위한 손쉬운 사용 허용하기").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button("손쉬운 사용 허용...") { CommittedTextSelection.requestAccess() }
                        .buttonStyle(SettingsSmallButtonStyle())
                        .accessibilityIdentifier("allow-committed-text-editing")
                }
            }
            UpdateSettingsView(updates: .shared)
            Spacer(minLength: 0)
        }
    }
}

@MainActor
private struct CorrectionsSettingsPane: NSViewControllerRepresentable {
    let controller: CorrectionsViewController
    func makeNSViewController(context: Context) -> CorrectionsViewController {
        _ = controller.view
        controller.reload()
        return controller
    }
    func updateNSViewController(_ controller: CorrectionsViewController, context: Context) {}
}
