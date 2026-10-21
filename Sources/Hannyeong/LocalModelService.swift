import Foundation
import HannyeongCore
import os

@MainActor
enum LocalModelService {
    private static var cached: LocalDecisionClient?
    private static var cachedPersonal: PersonalStateSelection?
    private static let logger = Logger(subsystem: "com.yeop.inputmethod.Hannyeong", category: "LocalModel")

    static func client() throws -> LocalDecisionClient {
        if let cached { return cached }
        guard let url = Bundle.main.url(forResource: "local-runtime", withExtension: "json") else {
            throw LocalDecisionError(detail: "Local model runtime is not installed")
        }
        let saved = try JSONDecoder().decode(LocalRuntimeConfiguration.self, from: Data(contentsOf: url))
        let resources = url.deletingLastPathComponent()
        // Release builds bundle Python and store its path relative to Resources.
        let python = saved.python.hasPrefix("/") ? saved.python : resources.appendingPathComponent(saved.python).path
        let runtime = LocalRuntimeConfiguration(python: python,
            worker: resources.appendingPathComponent(saved.worker).path,
            model: resources.appendingPathComponent(saved.model).path)
        let personal = try selectPersonalState(model: URL(fileURLWithPath: runtime.model))
        let client = LocalDecisionClient(runtime: runtime, personalURL: personal.url)
        cached = client
        cachedPersonal = personal
        return client
    }

    private static var cachedFrequencies: WordFrequencies?

    static func wordFrequencies() throws -> WordFrequencies {
        if let cachedFrequencies { return cachedFrequencies }
        guard let url = Bundle.main.url(forResource: "rule-lexicon", withExtension: "json") else {
            throw LocalDecisionError(detail: "Word frequency lexicon is not installed")
        }
        let frequencies = try WordFrequencies.load(url)
        cachedFrequencies = frequencies
        return frequencies
    }

    /// The personal correction file chosen for the bundled model, for the settings window.
    static func personalState() throws -> PersonalStateSelection {
        _ = try client()
        return cachedPersonal!
    }

    private static func selectPersonalState(model: URL) throws -> PersonalStateSelection {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Hannyeong")
        let selection: PersonalStateSelection
        do {
            selection = try PersonalState.select(directory: directory, modelID: PersonalState.modelID(ofModel: model))
        } catch {
            logger.error("Personal state selection failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        if let migrated = selection.migratedLegacy {
            logger.notice("Renamed \(PersonalState.legacyName, privacy: .public) to \(migrated.lastPathComponent, privacy: .public)")
        }
        let origin = selection.origin == .existing ? "existing" : "new"
        let others = selection.otherModelFiles.map(\.lastPathComponent).joined(separator: ",")
        logger.notice("Personal state for model \(selection.modelID, privacy: .public): \(selection.url.lastPathComponent, privacy: .public) (\(origin, privacy: .public)); kept other-model files not applied: [\(others, privacy: .public)]")
        return selection
    }
}
