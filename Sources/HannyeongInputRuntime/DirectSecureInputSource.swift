import AppKit
import Carbon
import os

/// Observes system state only; secure text and keyboard events never enter this monitor.
@MainActor
final class DirectSecureInputSource: NSObject {
    private static let abc = "com.apple.keylayout.ABC"
    private let sourceID: String
    private let isSecure: @MainActor () -> Bool
    private let currentSource: @MainActor () -> String
    private let selectSource: @MainActor (String) throws -> Void
    private let asciiLayout: @MainActor () -> String?
    private let entering: @MainActor () -> Void
    private let restored: @MainActor () -> Void
    private let poll: @MainActor () -> Void
    private let now: @MainActor () -> TimeInterval
    private let logger = Logger(subsystem: "com.yeop.HannyeongInputRuntime", category: "SecureInput")
    private var timer: Timer?
    private var previousSource: String
    /// The enabled ASCII keyboard layout used while secure input is active. ABC can be disabled, so it is looked up per episode.
    private var ascii: String?
    private var secure = false
    private var restoreDirect = false
    private var exitCandidate: (source: String, since: TimeInterval)?
    private var failed = false

    init(sourceID: String, entering: @escaping @MainActor () -> Void,
         restored: @escaping @MainActor () -> Void = {},
         isSecure: @escaping @MainActor () -> Bool = { IsSecureEventInputEnabled() },
         currentSource: @escaping @MainActor () -> String = DirectSecureInputSource.systemSource,
         selectSource: @escaping @MainActor (String) throws -> Void = DirectSecureInputSource.systemSelect,
         asciiLayout: @escaping @MainActor () -> String? = DirectSecureInputSource.systemASCIILayout,
         poll: @escaping @MainActor () -> Void = {},
         now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.sourceID = sourceID
        self.entering = entering
        self.restored = restored
        self.isSecure = isSecure
        self.currentSource = currentSource
        self.selectSource = selectSource
        self.asciiLayout = asciiLayout
        self.poll = poll
        self.now = now
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
        // The secure episode stays open while its exit settles. Other unchanged ticks do no source lookup.
        guard enabled != secure || exitCandidate != nil else { return }
        update(enabled: enabled, source: currentSource())
    }

    func sourceChanged() {
        guard !failed else { return }
        update(enabled: isSecure(), source: currentSource())
    }

    func isTemporaryABC(_ source: String) -> Bool {
        secure && restoreDirect && source == ascii
    }

    var shouldObserveSudo: Bool { previousSource == sourceID || restoreDirect }

    private func update(enabled: Bool, source: String) {
        do {
            if enabled {
                exitCandidate = nil
                if !secure {
                    ascii = asciiLayout()
                    restoreDirect = source == sourceID || (source == ascii && previousSource == sourceID)
                    secure = true
                    if restoreDirect { entering(); logger.notice("Secure input entered; remembering selected input source") }
                }
                if source == sourceID {
                    if !restoreDirect { restoreDirect = true; entering() }
                    if let ascii {
                        try selectSource(ascii)
                        logger.notice("Secure input source selected: \(ascii, privacy: .public)")
                    } else {
                        logger.error("Secure input has no enabled ASCII keyboard layout; keeping the current source")
                    }
                }
            } else {
                let restore = secure && restoreDirect && (source == ascii || source == sourceID)
                if restore {
                    // Login submission can briefly release secure input before its final
                    // source change. Finish only after the source and secure exit are quiet.
                    let time = now()
                    guard let candidate = exitCandidate, candidate.source == source else {
                        exitCandidate = (source, time)
                        return
                    }
                    guard time - candidate.since >= 0.2 else { return }
                    if source == ascii { try selectSource(sourceID) }
                    let selected = currentSource()
                    guard selected == sourceID else {
                        throw NSError(domain: "HannyeongDirect.SecureInput", code: -2,
                            userInfo: [NSLocalizedDescriptionKey: "Input source restoration was not applied: \(selected)"])
                    }
                    if source == ascii {
                        exitCandidate = (selected, time)
                        return
                    }
                    previousSource = selected
                } else {
                    previousSource = source
                }
                secure = false
                restoreDirect = false
                exitCandidate = nil
                ascii = nil
                if restore {
                    restored()
                    logger.notice("Secure input ended; input source restored")
                }
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

    /// Prefers ABC, then the last used ASCII layout, then any enabled ASCII layout.
    private static func systemASCIILayout() -> String? {
        let filter = [kTISPropertyInputSourceType: kTISTypeKeyboardLayout,
                      kTISPropertyInputSourceIsASCIICapable: true,
                      kTISPropertyInputSourceIsSelectCapable: true] as CFDictionary
        // A filter with no enabled match returns NULL, not an empty list.
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        let ids = list.compactMap(id)
        if ids.contains(abc) { return abc }
        if let last = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
           let lastID = id(last), ids.contains(lastID) { return lastID }
        return ids.first
    }

    private static func id(_ source: TISInputSource) -> String? {
        guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    private static func systemSelect(_ id: String) throws {
        // Disabled or unknown IDs return NULL, not an empty list.
        guard let sources = TISCreateInputSourceList([kTISPropertyInputSourceID: id] as CFDictionary, false)?
                .takeRetainedValue() as? [TISInputSource],
              let source = sources.first else {
            throw NSError(domain: "HannyeongDirect.SecureInput", code: -1, userInfo: [NSLocalizedDescriptionKey: "Input source unavailable: \(id)"])
        }
        let status = TISSelectInputSource(source)
        guard status == noErr else { throw NSError(domain: "HannyeongDirect.SecureInput", code: Int(status)) }
    }
}
