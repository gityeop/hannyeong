import AppKit
import InputMethodKit

enum CompositionPreviewSettings {
    static let liveEnabledKey = "coordinator.qa.live"
}
enum PriorWordCorrectionSettings {
    static func enabled(in defaults: UserDefaults) -> Bool { true }
}
enum LocalModelService {
    static func client() throws -> Int { 0 }
    static func wordFrequencies() throws -> Int { 0 }
}
final class CorrectionStore {
    static let shared = CorrectionStore()
    let url = URL(fileURLWithPath: "/unused/coordinator-test")
    func load() -> Int { 0 }
}
