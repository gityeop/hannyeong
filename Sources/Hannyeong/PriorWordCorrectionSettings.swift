import Foundation

enum PriorWordCorrectionSettings {
    static let enabledKey = "composition.priorWordCorrectionEnabled"

    static func enabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }
}
