import Foundation
import HannyeongCore

/// Uses Hannyeong's existing candidate builder, correction memory and local worker unchanged.
actor DirectRuntime {
    nonisolated let client: LocalDecisionClient
    private var memory: CorrectionMemory
    private let correctionsURL: URL
    private let frequencies: WordFrequencies
    private let reloadCorrections: Bool
    private var toggle: (wordID: UUID, raw: String, before: String, preferred: String, prior: CorrectionExample?)?

    init(resources: URL, personalDirectory: URL, memory: CorrectionMemory) throws {
        let saved = try JSONDecoder().decode(LocalRuntimeConfiguration.self,
            from: Data(contentsOf: resources.appendingPathComponent("local-runtime.json")))
        let runtime = LocalRuntimeConfiguration(
            python: saved.python.hasPrefix("/") ? saved.python : resources.appendingPathComponent(saved.python).path,
            worker: resources.appendingPathComponent(saved.worker).path,
            model: resources.appendingPathComponent(saved.model).path)
        let modelID = try PersonalState.modelID(ofModel: URL(fileURLWithPath: runtime.model))
        self.client = LocalDecisionClient(runtime: runtime,
            personalURL: personalDirectory.appendingPathComponent(PersonalState.fileName(for: modelID)))
        self.memory = memory
        self.correctionsURL = personalDirectory.appendingPathComponent("corrections.json")
        self.reloadCorrections = false
        self.frequencies = try WordFrequencies.load(resources.appendingPathComponent("rule-lexicon.json"))
    }

    init(client: LocalDecisionClient, frequencies: WordFrequencies, correctionsURL: URL, memory: CorrectionMemory) {
        self.client = client
        self.frequencies = frequencies
        self.correctionsURL = correctionsURL
        self.memory = memory
        self.reloadCorrections = true
    }

    func decide(_ request: DirectSession.Snapshot) async throws -> DirectSession.Decision {
        if let text = request.manualText {
            return .boundary(.init(text: text, replacement: nil, next: nil))
        }
        let current = try await reading(raw: request.raw, before: request.before)
        guard let separator = request.separator else { return .live(try .init(text: current.text, raw: request.raw)) }
        guard request.backfillEnabled else { return .boundary(.init(text: current.text, replacement: nil, next: nil)) }
        let alternate: DirectBackfill.Reading?
        if let recent = request.recent {
            alternate = try await reading(raw: request.raw, before: recent.alternateContext)
        } else { alternate = nil }
        return .boundary(try DirectBackfill.resolve(word: .init(raw: request.raw, separator: separator),
            before: request.before, previous: request.recent, decided: current, alternate: alternate, frequencies: frequencies))
    }

    private func reading(raw: String, before: String) async throws -> DirectBackfill.Reading {
        if reloadCorrections { try reloadMemory() }
        let candidates = try CandidateBuilder.candidates(for: raw, includeSplits: true)
        if let preferred = memory.preferred(raw: raw, before: before) {
            guard candidates.contains(where: { $0.text == preferred }) else {
                throw DirectFailure(detail: "The saved correction is not a valid direct-input candidate.")
            }
            return .init(text: preferred, probabilities: [preferred: 1])
        }
        let decision = try await client.decide(raw: raw, before: before, candidates: candidates)
        return .init(text: decision.predicted, probabilities: Dictionary(uniqueKeysWithValues:
            candidates.map { ($0.text, decision.probabilities[$0.id]!) }))
    }

    func correct(_ target: DirectSession.FeedbackTarget, preferred: String) async throws {
        toggle = nil
        if reloadCorrections { try reloadMemory() }
        var updated = memory
        try updated.record(raw: target.raw, before: target.before, rejected: target.text, preferred: preferred, scope: .context)
        try JSONEncoder().encode(updated).write(to: correctionsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: correctionsURL.path)
        memory = updated
        let candidates = try CandidateBuilder.candidates(for: target.raw, includeSplits: true)
        _ = try await client.correct(raw: target.raw, before: target.before, candidates: candidates, preferred: preferred, scope: .context)
    }

    /// Preserve the original input method's odd/even single-tap learning semantics.
    func rememberToggle(_ target: DirectSession.FeedbackTarget, preferred: String) async throws {
        try reloadMemory()
        let candidates = try CandidateBuilder.candidates(for: target.raw, includeSplits: true)
        if let previous = toggle, previous.wordID == target.wordID, previous.raw == target.raw, previous.before == target.before,
           previous.preferred == target.text {
            if let entry = memory.entries.last(where: { $0.raw == target.raw && $0.scope == .always }) {
                try memory.remove(entry)
            }
            if let prior = previous.prior {
                try memory.record(raw: prior.raw, before: prior.before, rejected: prior.rejected, preferred: prior.preferred, scope: .always)
            }
            try saveMemory()
            toggle = nil
            if let prior = previous.prior {
                _ = try await client.correct(raw: prior.raw, before: prior.before, candidates: candidates, preferred: prior.preferred, scope: .always)
            } else {
                _ = try await client.forget(raw: target.raw, before: target.before, preferred: target.text, scope: .always)
            }
        } else {
            let prior = memory.entries.last(where: { $0.raw == target.raw && $0.scope == .always })
            try memory.record(raw: target.raw, before: target.before, rejected: target.text, preferred: preferred, scope: .always)
            try saveMemory()
            toggle = (target.wordID, target.raw, target.before, preferred, prior)
            _ = try await client.correct(raw: target.raw, before: target.before, candidates: candidates, preferred: preferred, scope: .always)
        }
    }

    private func reloadMemory() throws {
        if FileManager.default.fileExists(atPath: correctionsURL.path) {
            memory = try JSONDecoder().decode(CorrectionMemory.self, from: Data(contentsOf: correctionsURL))
        }
    }

    private func saveMemory() throws {
        try JSONEncoder().encode(memory).write(to: correctionsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: correctionsURL.path)
    }

    static func installed(resources: URL) throws -> DirectRuntime {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let original = support.appendingPathComponent("Hannyeong")
        let directory = support.appendingPathComponent("HannyeongDirectPrototype")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let saved = try JSONDecoder().decode(LocalRuntimeConfiguration.self,
            from: Data(contentsOf: resources.appendingPathComponent("local-runtime.json")))
        let modelID = try PersonalState.modelID(ofModel: resources.appendingPathComponent(saved.model))
        // Snapshot existing personal data once; the prototype never writes to the original files.
        for name in [PersonalState.fileName(for: modelID), "corrections.json"] {
            let source = original.appendingPathComponent(name), destination = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: destination.path), FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
        }
        let corrections = directory.appendingPathComponent("corrections.json")
        let memory = FileManager.default.fileExists(atPath: corrections.path)
            ? try JSONDecoder().decode(CorrectionMemory.self, from: Data(contentsOf: corrections)) : CorrectionMemory()
        return try DirectRuntime(resources: resources, personalDirectory: directory, memory: memory)
    }
}
