import AppKit
import HannyeongCore

/// The native input source and Direct use one nonblocking physical-key owner.
@MainActor
public final class TypingEngine {
    public static let directSourceID = "com.yeop.inputmethod.HannyeongDirectSource"
    public static var currentSourceID: String { DirectInputSource.current() }

    private let runtime: DirectRuntime
    private var input: DirectInputTap!
    private var routeMonitor: InputRouteMonitor!
    private var panel: FeedbackPanel?
    private var previewGeneration = 0
    public var onPreview: ((String, String) -> Void)?
    public var enabled: Bool { input.enabled }

    public convenience init(resources: URL, changed: @escaping (Bool) -> Void, failure: @escaping (Error) -> Void) throws {
        try self.init(runtime: DirectRuntime.installed(resources: resources), sourceID: Self.directSourceID,
                      native: false, changed: changed, failure: failure)
    }

    public static func native(client: LocalDecisionClient, frequencies: WordFrequencies,
                              correctionsURL: URL, memory: CorrectionMemory,
                              replaceNativeSheet: ((String, String) throws -> Void)? = nil,
                              failure: @escaping (Error) -> Void) throws -> TypingEngine {
        try TypingEngine(runtime: DirectRuntime(client: client, frequencies: frequencies, correctionsURL: correctionsURL, memory: memory),
                         sourceID: "com.yeop.inputmethod.Hannyeong", native: true, changed: { _ in }, failure: failure,
                         replaceNativeSheet: replaceNativeSheet)
    }

    private init(runtime: DirectRuntime, sourceID: String, native: Bool,
                 changed: @escaping (Bool) -> Void, failure: @escaping (Error) -> Void,
                 replaceNativeSheet: ((String, String) throws -> Void)? = nil) throws {
        self.runtime = runtime
        input = try DirectInputTap(decide: { try await runtime.decide($0) }, changed: changed, failure: failure,
            showFeedback: { [weak self] candidates, bounds in
                guard let self else { return }
                if self.panel == nil { self.panel = FeedbackPanel() }
                self.panel?.show(candidates: candidates, scope: .context,
                    at: NSRect(x: bounds.minX, y: NSScreen.screens.first!.frame.maxY - bounds.maxY,
                               width: bounds.width, height: bounds.height)) { [weak self] index in
                        self?.input.chooseFeedback(index)
                    }
            }, hideFeedback: { [weak self] in self?.panel?.hide() },
            feedbackCommand: { [weak self] code, text in self?.panel?.handle(code: code, text: text) == true },
            feedbackContains: { [weak self] in self?.panel?.contains($0) == true },
            correct: { try await runtime.correct($0, preferred: $1) },
            previewChanged: { [weak self] raw, displayed in
                guard let self, let preview = self.onPreview else { return }
                self.previewGeneration += 1
                let generation = self.previewGeneration
                DispatchQueue.main.async { [weak self] in
                    guard self?.previewGeneration == generation else { return }
                    preview(raw, displayed)
                }
            }, sourceID: sourceID, managesInputSource: !native, replaceNativeSheet: replaceNativeSheet,
            invalidateRoute: { [weak self] in self?.routeMonitor?.invalidate() },
            refreshRoute: { [weak self] in self?.routeMonitor?.refresh() })
        routeMonitor = InputRouteMonitor(sourceID: sourceID, checking: { [weak self] in self?.input.beginRouteCheck() }) { [weak self] target, known, keyboardPIDs in
            self?.input.systemKeyboardPIDs = keyboardPIDs
            self?.input.updateRoute(target, known: known)
        }
        routeMonitor.start()
    }

    public func prepare() async throws { _ = try await runtime.client.prepare() }
    public func start(restoring source: String? = nil) throws {
        try input.start(restoring: source)
        routeMonitor.resume()
    }
    public func pause() throws { try input.pause() }
    public func close() throws { routeMonitor.stop(); try input.close() }
    public func reset() { input.reset() }
    public func resumeAfterSecureInput() { routeMonitor.resume() }
    public func recheckInputTarget() { routeMonitor.refresh() }
    public func dismissCandidates() { input.dismissCandidates() }
    public func configure(live: Bool, fixedEnglish: Bool?, backfill: Bool) {
        input.configure(live: live, fixedEnglish: fixedEnglish, backfill: backfill)
    }
}
