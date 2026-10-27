import AppKit
import Carbon
import os

/// Observes system state only; secure text and keyboard events never enter this monitor.
@MainActor
final class DirectSecureInputSource: NSObject {
    private static let ascii = "com.apple.keylayout.ABC"
    private let sourceID: String
    private let isSecure: @MainActor () -> Bool
    private let currentSource: @MainActor () -> String
    private let selectSource: @MainActor (String) throws -> Void
    private let entering: @MainActor () -> Void
    private let poll: @MainActor () -> Void
    private let logger = Logger(subsystem: "com.yeop.HannyeongInputRuntime", category: "SecureInput")
    private var timer: Timer?
    private var previousSource: String
    private var secure = false
    private var restoreDirect = false
    private var failed = false

    init(sourceID: String, entering: @escaping @MainActor () -> Void,
         isSecure: @escaping @MainActor () -> Bool = { IsSecureEventInputEnabled() },
         currentSource: @escaping @MainActor () -> String = DirectSecureInputSource.systemSource,
         selectSource: @escaping @MainActor (String) throws -> Void = DirectSecureInputSource.systemSelect,
         poll: @escaping @MainActor () -> Void = {}) {
        self.sourceID = sourceID
        self.entering = entering
        self.isSecure = isSecure
        self.currentSource = currentSource
        self.selectSource = selectSource
        self.poll = poll
        previousSource = currentSource()
    }

    func start() {
        let timer = Timer(timeInterval: 0.1, target: self, selector: #selector(check), userInfo: nil, repeats: true)
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
        logger.notice("Secure input source monitor active")
    }

    func stop() { timer?.invalidate(); timer = nil }

    @objc func check() {
        guard !failed else { return }
        poll()
        let enabled = isSecure()
        // No input-source lookup on unchanged polling ticks, and no work on the key path.
        guard enabled != secure else { return }
        update(enabled: enabled, source: currentSource())
    }

    func sourceChanged() {
        guard !failed else { return }
        update(enabled: isSecure(), source: currentSource())
    }

    func isTemporaryABC(_ source: String) -> Bool {
        secure && restoreDirect && source == Self.ascii
    }

    var shouldObserveSudo: Bool { previousSource == sourceID || restoreDirect }

    private func update(enabled: Bool, source: String) {
        do {
            if enabled {
                if !secure {
                    restoreDirect = source == sourceID || (source == Self.ascii && previousSource == sourceID)
                    secure = true
                    if restoreDirect { entering(); logger.notice("Secure input entered; remembering selected input source") }
                }
                if source == sourceID {
                    if !restoreDirect { restoreDirect = true; entering() }
                    try selectSource(Self.ascii)
                    logger.notice("Secure input source selected: ABC")
                }
            } else {
                let restore = secure && restoreDirect && source == Self.ascii
                secure = false
                restoreDirect = false
                if restore {
                    try selectSource(sourceID)
                    logger.notice("Secure input ended; input source restored")
                }
                previousSource = currentSource()
            }
        } catch {
            failed = true
            stop()
            logger.error("Secure input source selection failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func systemSource() -> String {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)!
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    private static func systemSelect(_ id: String) throws {
        let sources = TISCreateInputSourceList([kTISPropertyInputSourceID: id] as CFDictionary, false).takeRetainedValue() as! [TISInputSource]
        guard let source = sources.first else {
            throw NSError(domain: "HannyeongDirect.SecureInput", code: -1, userInfo: [NSLocalizedDescriptionKey: "Input source unavailable: \(id)"])
        }
        let status = TISSelectInputSource(source)
        guard status == noErr else { throw NSError(domain: "HannyeongDirect.SecureInput", code: Int(status)) }
    }
}
