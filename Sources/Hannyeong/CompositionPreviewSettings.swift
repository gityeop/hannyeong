import Foundation

enum CompositionPreviewSettings {
    static let defaultKey = "composition.previewEnglish"
    static let applicationsKey = "composition.previewByBundleID"
    static let alternateEnabledKey = "composition.alternatePreviewEnabled"
    static let alternateSizeKey = "composition.alternatePreviewSize"

    enum AlternateSize: String, CaseIterable {
        case small, medium, large

        var title: String {
            switch self {
            case .small: "작게"
            case .medium: "보통"
            case .large: "크게"
            }
        }

        var fontSize: CGFloat {
            switch self {
            case .small: 11
            case .medium: 13
            case .large: 16
            }
        }
    }

    static func alternateSize(in defaults: UserDefaults) -> AlternateSize {
        guard let raw = defaults.string(forKey: alternateSizeKey) else { return .medium }
        return AlternateSize(rawValue: raw)!
    }

    static func alternateEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: alternateEnabledKey) as? Bool ?? true
    }

    static func applications(in defaults: UserDefaults) -> [String: Bool] {
        defaults.dictionary(forKey: applicationsKey) as? [String: Bool] ?? [:]
    }

    static func english(for bundleID: String?, in defaults: UserDefaults) -> Bool {
        if let bundleID, let english = applications(in: defaults)[bundleID] { return english }
        return defaults.bool(forKey: defaultKey)
    }

    static func set(_ english: Bool?, for bundleID: String, in defaults: UserDefaults) {
        var applications = applications(in: defaults)
        applications[bundleID] = english
        defaults.set(applications, forKey: applicationsKey)
    }
}
