import AppKit
import Foundation

public struct DirectFailure: Error {
    public let detail: String
}

@MainActor public final class TypingEngine {
    public enum ClientOwner { case kakaoTalk, openAI }
    public static var currentSourceID: String { "com.yeop.inputmethod.Hannyeong" }
    public static var hasKeyboardAccess: Bool { true }
    public static var latest: TypingEngine!
    public private(set) var enabled = false
    public private(set) var resetCount = 0
    private var owner: ClientOwner?
    private let replaceText: (Int, String) throws -> Void
    private let resetText: (NativeCaretReset) -> Void
    private let failure: (Error) -> Void

    private init(replaceText: @escaping (Int, String) throws -> Void,
                 resetText: @escaping (NativeCaretReset) -> Void,
                 failure: @escaping (Error) -> Void) {
        self.replaceText = replaceText
        self.resetText = resetText
        self.failure = failure
    }

    public static func native(client: Int, frequencies: Int, correctionsURL: URL, memory: Int,
                              replaceNativeSheet: @escaping (String, String) throws -> Void,
                              replaceNativeText: @escaping (Int, String) throws -> Void,
                              resetNativeText: @escaping (NativeCaretReset) -> Void,
                              advanceNativeText: @escaping (Int) -> Void,
                              failure: @escaping (Error) -> Void) throws -> TypingEngine {
        let engine = TypingEngine(replaceText: replaceNativeText, resetText: resetNativeText,
                                  failure: failure)
        latest = engine
        return engine
    }

    public func start() throws { enabled = true }
    public func pause() throws { enabled = false }
    public func close() throws { enabled = false }
    public func configure(live: Bool, fixedEnglish: Bool?, backfill: Bool) {}
    public func recheckInputTarget() {}
    public func resumeAfterSecureInput() {}
    public func dismissCandidates() {}
    public func reset() {
        resetCount += 1
        resetText(.newContext)
    }
    public func setNativeClientOwner(_ next: ClientOwner?) {
        if owner != next { reset() }
        owner = next
    }
    public func handleNative(_ event: CGEvent) -> Bool {
        do {
            try replaceText(0, "ㅇ")
            return true
        } catch {
            failure(error)
            return false
        }
    }
}
