import AppKit
import ApplicationServices
import Carbon
import HannyeongCore
import os

/// Main-run-loop event owner. Model I/O is asynchronous; all output is emitted inside the tap.
final class DirectInputTap {
    private let decide: (DirectSession.Snapshot) async throws -> DirectSession.Decision
    private let changed: (Bool) -> Void
    private let failure: (Error) -> Void
    private let captureFocus: () throws -> DirectFocus?
    private let validateFocus: (DirectFocus) throws -> Bool
    private let invalidateRoute: () -> Void
    private let refreshRoute: () -> Void
    private let post: (CGEvent, CGEventTapProxy) -> Void
    private let wake: () throws -> Void
    private let keyboard: KeyboardInput
    private let showFeedback: ([String], CGRect) -> Void
    private let caretBounds: (DirectFocus) throws -> CGRect
    private let hideFeedback: () -> Void
    private let feedbackCommand: (Int64, String) -> Bool
    private let feedbackContains: (CGEvent) -> Bool
    private let correct: (DirectSession.FeedbackTarget, String) async throws -> Void
    private let previewChanged: (String, String) -> Void
    private let sourceID: String
    private let managesInputSource: Bool
    private let replaceNativeSheet: ((String, String) throws -> Void)?
    private let latencyLogger: Logger
    private var lastRoutingState: String?
    private var observedFirstCommand = false
    private var liveDetection = true
    private var fixedLanguage: DirectBackfill.Language?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var commandTap: CFMachPort?
    private var commandSource: CFRunLoopSource?
    private var textRoute: DirectFocus?
    private var routeKnown = false
    private var routeChecking = false
    private var passthroughWord = false
    private var passthroughPID: Int64?
    private var functionKeysHeld: Set<Int64> = []
    private var session = DirectSession()
    private var focus: DirectFocus?
    private var routingEvent: CGEvent?
    private var generation = 0
    private var modelTask: Task<Void, Never>?
    private var ready: (DirectSession.Snapshot, DirectSession.Decision, DirectFocus)?
    private var lastDecided: DirectSession.Snapshot?
    private var basicDecision: (DirectSession.Snapshot, DirectSession.Projection)?
    private var rightCommand = DirectRightCommandTap()
    private var singleTimer: DispatchWorkItem?
    private var singleReady = false
    private var feedbackTarget: DirectSession.FeedbackTarget?
    private var feedbackProjections: [DirectSession.Projection] = []
    private var feedbackFocus: DirectFocus?
    private enum FeedbackResult {
        case candidates(DirectSession.FeedbackTarget, [DirectSession.Projection], DirectFocus, CGRect)
        case selection(DirectSession.FeedbackTarget, DirectSession.Projection, DirectFocus)
    }
    private var readyFeedback: FeedbackResult?
    private var consumed: Set<Int64> = []
    private var previousSource: String?
    private let preferencesQueue = DispatchQueue(label: "com.yeop.HannyeongDirectPrototype.Preferences", qos: .utility)
    private(set) var enabled = false
    var systemKeyboardPIDs: Set<Int64> = []

    init(decide: @escaping (DirectSession.Snapshot) async throws -> DirectSession.Decision,
         changed: @escaping (Bool) -> Void, failure: @escaping (Error) -> Void,
         captureFocus: @escaping () throws -> DirectFocus? = DirectFocus.capture,
         validateFocus: ((DirectFocus) throws -> Bool)? = nil,
         post: @escaping (CGEvent, CGEventTapProxy) -> Void = { $0.tapPostEvent($1) },
         wake: @escaping () throws -> Void = { try KeyboardOutput.wake().post(tap: KeyboardOutput.tapLocation) },
         showFeedback: @escaping ([String], CGRect) -> Void = { _, _ in },
         caretBounds: @escaping (DirectFocus) throws -> CGRect = { try $0.caretBounds() },
         hideFeedback: @escaping () -> Void = {},
         feedbackCommand: @escaping (Int64, String) -> Bool = { _, _ in false },
         feedbackContains: @escaping (CGEvent) -> Bool = { _ in false },
         correct: @escaping (DirectSession.FeedbackTarget, String) async throws -> Void = { _, _ in },
         previewChanged: @escaping (String, String) -> Void = { _, _ in },
         sourceID: String = DirectInputSource.direct, managesInputSource: Bool = true,
         replaceNativeSheet: ((String, String) throws -> Void)? = nil,
         invalidateRoute: @escaping () -> Void = {}, refreshRoute: @escaping () -> Void = {}) throws {
        keyboard = try KeyboardInput()
        self.decide = decide
        self.changed = changed
        self.failure = failure
        self.captureFocus = captureFocus
        self.validateFocus = validateFocus ?? { try $0.validate() }
        self.invalidateRoute = invalidateRoute
        self.refreshRoute = refreshRoute
        self.post = post
        self.wake = wake
        self.showFeedback = showFeedback
        self.caretBounds = caretBounds
        self.hideFeedback = hideFeedback
        self.feedbackCommand = feedbackCommand
        self.feedbackContains = feedbackContains
        self.correct = correct
        self.previewChanged = previewChanged
        self.sourceID = sourceID
        self.managesInputSource = managesInputSource
        self.replaceNativeSheet = replaceNativeSheet
        self.latencyLogger = Logger(subsystem: sourceID, category: "TypingLatency")
    }

    func configure(live: Bool, fixedEnglish: Bool?, backfill: Bool) {
        let language: DirectBackfill.Language? = fixedEnglish.map { $0 ? .english : .korean }
        guard liveDetection != live || fixedLanguage != language || session.backfillEnabled != backfill else { return }
        reset()
        liveDetection = live
        fixedLanguage = language
        session.backfillEnabled = backfill
    }

    #if DIRECT_INPUT_QA
    func enableForQA() {
        enabled = true
        let element = AXUIElementCreateApplication(getpid() + 1234)
        updateRoute(DirectFocus(pid: getpid() + 1234, field: element, window: element, commands: .keyBindings), known: true)
    }
    func completeSingleTapForQA() { singleReady = true; try! wake() }
    #endif

    func start(restoring sourceToRestore: String? = nil) throws {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw DirectFailure(detail: "Accessibility permission is required for Hannyeong Direct.")
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.hebbian.catchtype").isEmpty,
              NSWorkspace.shared.runningApplications.allSatisfy({ $0.localizedName != "Catchtype" }) else {
            throw DirectFailure(detail: "Quit Catchtype before enabling Hannyeong Direct.")
        }
        if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            throw DirectFailure(detail: "The keyboard tap is disabled. Quit and reopen Hannyeong Direct.")
        }
        if let commandTap, !CGEvent.tapIsEnabled(tap: commandTap) {
            throw DirectFailure(detail: "The command-boundary observer is disabled. Restart the input method.")
        }
        if tap == nil {
            let types: [CGEventType] = [.null, .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                        .leftMouseUp, .rightMouseUp, .otherMouseUp]
            let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            // Read the final application target after global handlers and session routing.
            guard let tap = CGEvent.tapCreate(tap: KeyboardOutput.tapLocation, place: .tailAppendEventTap,
                options: .defaultTap, eventsOfInterest: mask, callback: { proxy, type, event, context in
                    let owner = Unmanaged<DirectInputTap>.fromOpaque(context!).takeUnretainedValue()
                    return owner.receive(proxy, type, event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                throw DirectFailure(detail: "The direct-input keyboard tap could not be created.")
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)!
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            self.tap = tap
            self.source = source
        }
        if commandTap == nil {
            let mask = [CGEventType.keyDown, .keyUp].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            guard let observer = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
                    let owner = Unmanaged<DirectInputTap>.fromOpaque(context!).takeUnretainedValue()
                    owner.observeCommand(type, event)
                    return Unmanaged.passUnretained(event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                throw DirectFailure(detail: "The command-boundary observer could not be created.")
            }
            let runSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, observer, 0)!
            CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes)
            commandTap = observer
            commandSource = runSource
        }
        let previous = DirectInputSource.current()
        let language: DirectBackfill.Language
        if let fixedLanguage { language = fixedLanguage }
        else if !managesInputSource, let saved = UserDefaults.standard.string(forKey: "direct.preferredLanguage"),
                let preferred = DirectBackfill.Language(rawValue: saved) { language = preferred }
        else { language = try DirectInputSource.initialLanguage(for: previous) }
        latencyLogger.notice("Typing start; selectedSource=\(previous, privacy: .public) initialLanguage=\(language.rawValue, privacy: .public) managesSource=\(self.managesInputSource)")
        if managesInputSource {
            try DirectInputSource.select(sourceID)
            previousSource = sourceToRestore ?? previous
        } else {
            guard previous == sourceID else { throw DirectFailure(detail: "The native typing source is not selected.") }
        }
        session.setInitialLanguage(language)
        enabled = true
        lastRoutingState = nil
        observedFirstCommand = false
        functionKeysHeld.removeAll()
        changed(true)
    }

    func pause() throws {
        enabled = false
        reset()
        consumed.removeAll()
        functionKeysHeld.removeAll()
        changed(false)
        let previous = previousSource
        previousSource = nil
        if managesInputSource, DirectInputSource.current() == sourceID, let previous {
            try DirectInputSource.select(previous)
        }
    }

    func close() throws {
        try pause()
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let commandTap { CFMachPortInvalidate(commandTap) }
        if let commandSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), commandSource, .commonModes) }
        tap = nil
        source = nil
        commandTap = nil
        commandSource = nil
    }

    /// Focus/navigation invalidates old corrections. Host commands are never retained.
    func reset() {
        cancelRightCommand()
        closeFeedback()
        generation += 1
        // Let the one in-flight job finish and discard its generation. Canceling a Task
        // does not cancel worker pipe I/O and would allow new jobs to pile up behind it.
        ready = nil
        lastDecided = nil
        basicDecision = nil
        session.reset()
        focus = nil
        routingEvent = nil
        passthroughWord = false
        passthroughPID = nil
        previewChanged("", "")
    }

    func dismissCandidates() { closeFeedback(); requestDecision() }

    func beginRouteCheck() {
        routeChecking = true
        cancelRightCommand()
        closeFeedback()
    }

    func updateRoute(_ target: DirectFocus?, known: Bool) {
        let unchanged: Bool
        if let current = textRoute, let target { unchanged = current.matches(target) }
        else { unchanged = false }
        if !unchanged || !known {
            // Never start replacing the middle of a word whose first keys were passed through.
            let preservePassedWord = !routeKnown && passthroughWord && target != nil
            let passedPID = passthroughPID
            reset()
            passthroughWord = preservePassedWord
            if preservePassedWord { passthroughPID = passedPID }
        }
        textRoute = target
        routeKnown = known
        routeChecking = false
        if enabled, known, target != nil {
            if ready != nil { do { try wake() } catch { stop(error) } }
            else { requestDecision() }
        }
    }

    /// Listen-only: see command openers even if an earlier shortcut handler consumes them.
    func observeCommand(_ type: CGEventType, _ event: CGEvent) {
        guard enabled else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stop(DirectFailure(detail: "The system disabled the command-boundary observer. Restart the input method."))
            return
        }
        let marker = event.getIntegerValueField(.eventSourceUserData)
        guard marker != KeyboardOutput.outputMarker, marker != KeyboardOutput.wakeMarker else { return }
        if type == .keyDown, !observedFirstCommand {
            observedFirstCommand = true
            latencyLogger.notice("Keyboard observer received first key after resume; sourcePID=\(event.getIntegerValueField(.eventSourceUnixProcessID))")
        }
        guard !KeyboardInput.isSoftwareText(event, systemKeyboardPIDs: systemKeyboardPIDs) else { return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if KeyboardInput.isFunctionKey(code) {
            if type == .keyDown {
                functionKeysHeld.insert(code)
                reset()
                updateRoute(nil, known: false)
                invalidateRoute()
            } else if type == .keyUp {
                functionKeysHeld.remove(code)
                refreshRoute()
            }
        } else if type == .keyDown, !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
            reset()
            // A shortcut may edit the same field (e.g. Select All). Keep its identity
            // while checking; passed keys are owned only if that exact field is confirmed.
            beginRouteCheck()
            refreshRoute()
        } else if type == .keyDown, routeChecking || !routeKnown {
            // A new physical key is a new focus observation after an AX error.
            // The route worker checks it asynchronously; the key itself never waits.
            refreshRoute()
        }
    }

    private func stop(_ error: Error) {
        do { try pause() }
        catch { failure(error) }
        failure(error)
    }

    private func routeFailed(_ error: DirectFocus.RouteError) {
        latencyLogger.error("Input target inspection failed: \(error.detail, privacy: .public)")
        beginRouteCheck()
        // A fresh focus/menu/command/key event may classify a new route. Never retry AX here.
    }

    private func traceRouting(_ type: CGEventType, _ event: CGEvent) {
        guard enabled, type == .keyDown else { return }
        let state: String
        if KeyboardInput.isSoftwareText(event, systemKeyboardPIDs: systemKeyboardPIDs) { state = "software-text" }
        else if IsSecureEventInputEnabled() { state = "secure-input" }
        else if event.getIntegerValueField(.eventTargetUnixProcessID) > 0,
                let route = textRoute, !route.acceptsKeyboardTarget(event.getIntegerValueField(.eventTargetUnixProcessID)) { state = "target-mismatch" }
        else if textRoute == nil { state = "no-text-route" }
        else if !functionKeysHeld.isEmpty { state = "function-key-held" }
        else if passthroughWord { state = "unowned-word" }
        else if routeChecking { state = "checking-route" }
        else { state = "composing" }
        guard lastRoutingState != state else { return }
        lastRoutingState = state
        latencyLogger.notice("Typing route state=\(state, privacy: .public) known=\(self.routeKnown) checking=\(self.routeChecking) sourcePID=\(event.getIntegerValueField(.eventSourceUnixProcessID)) targetPID=\(event.getIntegerValueField(.eventTargetUnixProcessID)) routePID=\(self.textRoute?.pid ?? 0) sheet=\(self.textRoute?.sheet != nil)")
    }

    func receive(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let began = DispatchTime.now().uptimeNanoseconds
        defer {
            let elapsed = (DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
            if type == .keyDown, elapsed >= 16 {
                latencyLogger.notice("Key callback slow; ms=\(elapsed) enabled=\(self.enabled)")
            }
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stop(DirectFailure(detail: "The system disabled the direct-input keyboard tap. Restart the prototype."))
            return Unmanaged.passUnretained(event)
        }
        let marker = event.getIntegerValueField(.eventSourceUserData)
        if marker == KeyboardOutput.outputMarker { return Unmanaged.passUnretained(event) }
        if marker == KeyboardOutput.wakeMarker {
            if enabled, textRoute != nil, !routeChecking, functionKeysHeld.isEmpty {
                do {
                    if singleReady { singleReady = false; try applySingleTap(proxy) }
                    try applyFeedbackReady(proxy)
                    try applyReady(proxy)
                }
                catch { stop(error) }
            }
            return nil
        }
        traceRouting(type, event)
        if KeyboardInput.isSoftwareText(event, systemKeyboardPIDs: systemKeyboardPIDs) {
            if enabled, type == .keyDown { reset() }
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let modifiers = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate])
        if managesInputSource, type == .keyDown, code == 13, modifiers == [.maskControl, .maskAlternate] {
            do { if enabled { try pause() } else { try start() } }
            catch { stop(error) }
            consumed.insert(code)
            return nil
        }
        if type == .keyUp, consumed.remove(code) != nil { return nil }
        guard enabled else { return Unmanaged.passUnretained(event) }
        if type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp {
            if feedbackProjections.isEmpty || !feedbackContains(event) { refreshRoute() }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventTargetUnixProcessID) == Int64(getpid()),
           type == .keyDown || type == .keyUp || type == .flagsChanged {
            reset()
            return Unmanaged.passUnretained(event)
        }
        if IsSecureEventInputEnabled() {
            reset()
            return Unmanaged.passUnretained(event)
        }
        if KeyboardInput.isFunctionKey(code) {
            return Unmanaged.passUnretained(event)
        }
        let targetPID = event.getIntegerValueField(.eventTargetUnixProcessID)
        if type == .keyDown, let route = textRoute, !route.acceptsKeyboardTarget(targetPID) {
            // A command panel may own the keyboard while AX still reports a text field behind it.
            updateRoute(nil, known: false)
            refreshRoute()
        }
        if routeChecking, textRoute != nil, !passthroughWord {
            if type == .keyDown {
                if !modifiers.isEmpty || [36, 76, 48, 51, 53, 117, 115, 119, 116, 121, 123, 124, 125, 126].contains(code) {
                    reset()
                } else {
                    do {
                        let text = try keyboard.text(event)
                        let letters = !text.isEmpty && text.unicodeScalars.allSatisfy { (65...90).contains($0.value) || (97...122).contains($0.value) }
                        if letters {
                            try rememberRoute(event)
                            session.recordPassedLetters(text)
                        }
                        else if !session.raw.isEmpty, !text.isEmpty { session.beginBoundary(text) }
                        else if !text.isEmpty { session.recordSeparator(text) }
                    } catch { stop(error) }
                }
            } else if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
                updateRoute(nil, known: false)
                invalidateRoute()
            }
            return Unmanaged.passUnretained(event)
        }
        if passthroughWord, let passedPID = passthroughPID, passedPID > 0, targetPID > 0, targetPID != passedPID {
            passthroughWord = false
            passthroughPID = nil
        }
        if textRoute == nil || !functionKeysHeld.isEmpty || passthroughWord {
            cancelRightCommand()
            if type == .keyDown, modifiers.isEmpty {
                do {
                    let text = try keyboard.text(event)
                    let letters = !text.isEmpty && text.unicodeScalars.allSatisfy { (65...90).contains($0.value) || (97...122).contains($0.value) }
                    if !routeKnown, letters { passthroughWord = true; passthroughPID = targetPID }
                    if !letters { passthroughWord = false; passthroughPID = nil }
                } catch { stop(error) }
            }
            if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
                reset()
                refreshRoute()
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .flagsChanged, code == 54 {
            guard event.flags.intersection([.maskShift, .maskControl, .maskAlternate]).isEmpty,
                  event.flags.rawValue & 0x08 == 0 else {
                reset()
                return Unmanaged.passUnretained(event)
            }
            if event.flags.contains(.maskCommand) {
                closeFeedback()
                generation += 1
                ready = nil
                lastDecided = nil
            }
            switch rightCommand.handle(event) {
            case .waiting:
                singleTimer?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.singleReady = true
                    do { try self.wake() } catch { self.stop(error) }
                }
                singleTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + DirectRightCommandTap.interval, execute: work)
            case .correction:
                singleTimer?.cancel()
                singleReady = false
                requestFeedback()
            case nil: break
            }
            if !rightCommand.isPressed { requestDecision() }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown, modifiers.isEmpty {
            do { try applySingleTap(proxy) } catch { stop(error); return Unmanaged.passUnretained(event) }
            if feedbackTarget != nil {
                if !feedbackProjections.isEmpty {
                    if code == 53 { closeFeedback(); requestDecision(); consumed.insert(code); return nil }
                    let text: String
                    do { text = try keyboard.text(event) } catch { stop(error); return Unmanaged.passUnretained(event) }
                    if feedbackCommand(code, text) { consumed.insert(code); return nil }
                }
                closeFeedback()
            }
        }
        if type == .leftMouseDown, !feedbackProjections.isEmpty, feedbackContains(event) {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown || type == .flagsChanged || type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            cancelRightCommand()
        }
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown || !modifiers.isEmpty {
            reset()
            if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
                updateRoute(nil, known: false)
                invalidateRoute()
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .flagsChanged { return Unmanaged.passUnretained(event) }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        do {
            if try handle(event, proxy) {
                consumed.insert(code)
                return nil
            }
            return Unmanaged.passUnretained(event)
        } catch {
            stop(error)
            // The failed physical key was never synthesized. The original reaches the host once.
            return Unmanaged.passUnretained(event)
        }
    }

    /// Only locally composed letters/Delete are consumed. Boundaries reach the host immediately.
    private func handle(_ event: CGEvent, _ proxy: CGEventTapProxy) throws -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if code == 51, !session.raw.isEmpty {
            try emit(session.backspace(), proxy)
            requestDecision()
            return true
        }
        if code == 51 { reset(); return false }
        if code == 53 {
            if !session.raw.isEmpty { try emit(session.restoreRaw(), proxy) }
            reset()
            return false
        }
        if [36, 76, 48, 117, 115, 119, 116, 121, 123, 124, 125, 126].contains(code) {
            if code == 36 || code == 76 { try applyBasicDecision(proxy) }
            reset()
            return false
        }
        let text = try keyboard.text(event)
        let letters = !text.isEmpty && text.unicodeScalars.allSatisfy { (65...90).contains($0.value) || (97...122).contains($0.value) }
        if letters {
            try rememberRoute(event)
            if session.raw.isEmpty, let fixedLanguage { session.setInitialLanguage(fixedLanguage) }
            try emit(session.append(text), proxy)
            requestDecision()
            return true
        }
        if !session.raw.isEmpty {
            try applyBasicDecision(proxy)
            session.beginBoundary(text)
            previewChanged("", "")
            requestDecision()
            return false
        }
        if !text.isEmpty { session.recordSeparator(text); requestDecision() }
        return false
    }

    private func rememberRoute(_ event: CGEvent) throws {
        guard let routing = event.copy() else { throw DirectFailure(detail: "The input event routing metadata could not be retained.") }
        routingEvent = routing
    }

    private func emit(_ edit: DirectSession.Edit, _ proxy: CGEventTapProxy) throws {
        // Build the entire batch before the first mutation. There is one transport and no retry.
        guard let routingEvent else { throw DirectFailure(detail: "The output batch has no owned keyboard route.") }
        guard let textRoute else { throw DirectFailure(detail: "The output batch has no owned text field.") }
        let events = try KeyboardOutput.events(for: edit, routingEvent: routingEvent, commands: textRoute.commands)
        for event in events { post(event, proxy) }
        previewChanged(session.raw, session.displayed)
    }

    private func requestDecision() {
        guard enabled, textRoute != nil, !routeChecking, functionKeysHeld.isEmpty, !passthroughWord,
              !rightCommand.isPressed, !rightCommand.hasPending, feedbackTarget == nil,
              session.hasDecision, modelTask == nil, ready == nil, session.snapshot != lastDecided else { return }
        let request = session.snapshot, epoch = generation
        let decide = self.decide, captureFocus = self.captureFocus, validateFocus = self.validateFocus
        modelTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let began = DispatchTime.now().uptimeNanoseconds
            do {
                // AX messaging and candidate/model work must never run inside the key tap.
                guard let target = try captureFocus() else {
                    await MainActor.run {
                        self.modelTask = nil
                        guard self.enabled else { return }
                        if self.generation == epoch { self.beginRouteCheck(); self.refreshRoute() }
                        else { self.requestDecision() }
                    }
                    return
                }
                let text = try await decide(request)
                guard try validateFocus(target) else {
                    await MainActor.run {
                        self.modelTask = nil
                        guard self.enabled else { return }
                        if self.generation == epoch { self.beginRouteCheck(); self.refreshRoute() }
                        else { self.requestDecision() }
                    }
                    return
                }
                let elapsed = (DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
                if elapsed >= 100 { self.latencyLogger.notice("Background decision/focus slow; ms=\(elapsed)") }
                await MainActor.run {
                    self.modelTask = nil
                    guard self.enabled else { return }
                    guard self.generation == epoch, self.session.snapshot == request else { self.requestDecision(); return }
                    self.ready = (request, text, target)
                    if !self.routeChecking { do { try self.wake() } catch { self.stop(error) } }
                }
            } catch {
                await MainActor.run {
                    self.modelTask = nil
                    guard self.enabled else { return }
                    guard self.generation == epoch else { self.requestDecision(); return }
                    if let routeError = error as? DirectFocus.RouteError { self.routeFailed(routeError) }
                    else { self.stop(error) }
                }
            }
        }
    }

    private func cancelRightCommand() {
        rightCommand.cancel()
        singleTimer?.cancel()
        singleTimer = nil
        singleReady = false
    }

    private func applyBasicDecision(_ proxy: CGEventTapProxy) throws {
        guard !liveDetection else { return }
        try applyReady(proxy)
        guard let (request, projection) = basicDecision, session.snapshot == request,
              let edit = session.accept(projection, for: request) else { return }
        basicDecision = nil
        try emit(edit, proxy)
    }

    private func applySingleTap(_ proxy: CGEventTapProxy) throws {
        guard rightCommand.takeSingle() else { return }
        singleTimer?.cancel()
        singleReady = false
        generation += 1
        ready = nil
        lastDecided = nil
        let previous = session.feedbackTarget.map { $0.text + $0.separator }
        if let edit = try session.toggleLanguage() {
            if !managesInputSource, let route = textRoute, route.sheet != nil, let routingEvent,
               route.keyboardTargets.contains(routingEvent.getIntegerValueField(.eventTargetUnixProcessID)),
               let replaceNativeSheet, edit.deleteCount > 0 {
                guard let previous, previous.count >= edit.deleteCount else {
                    throw DirectFailure(detail: "The save-field language reversal has no owned suffix.")
                }
                try replaceNativeSheet(String(previous.suffix(edit.deleteCount)), edit.text)
                previewChanged(session.raw, session.displayed)
            } else {
                try emit(edit, proxy)
            }
        }
        requestDecision()
    }

    private func closeFeedback() {
        let visible = !feedbackProjections.isEmpty
        feedbackTarget = nil
        feedbackProjections.removeAll()
        feedbackFocus = nil
        readyFeedback = nil
        if visible { hideFeedback() }
    }

    private func requestFeedback() {
        closeFeedback()
        guard let target = session.feedbackTarget else { requestDecision(); return }
        feedbackTarget = target
        let epoch = generation, captureFocus = self.captureFocus, validateFocus = self.validateFocus, caretBounds = self.caretBounds
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                guard let focus = try captureFocus() else {
                    await MainActor.run { if self.generation == epoch { self.beginRouteCheck(); self.refreshRoute() } }
                    return
                }
                let candidates = try CandidateBuilder.candidates(for: target.raw, includeSplits: true)
                let projections = try candidates.map { try DirectSession.Projection(text: $0.text, raw: target.raw) }
                let bounds = try caretBounds(focus)
                guard try validateFocus(focus) else {
                    await MainActor.run { if self.generation == epoch { self.beginRouteCheck(); self.refreshRoute() } }
                    return
                }
                await MainActor.run {
                    guard self.enabled, self.generation == epoch, self.feedbackTarget == target,
                          self.session.feedbackTarget == target else { return }
                    self.readyFeedback = .candidates(target, projections, focus, bounds)
                    do { try self.wake() } catch { self.stop(error) }
                }
            } catch {
                await MainActor.run {
                    guard self.generation == epoch, self.feedbackTarget == target else { return }
                    if let routeError = error as? DirectFocus.RouteError { self.routeFailed(routeError) }
                    else { self.stop(error) }
                }
            }
        }
    }

    func chooseFeedback(_ index: Int) {
        guard let target = feedbackTarget, let focus = feedbackFocus,
              feedbackProjections.indices.contains(index) else { return }
        let projection = feedbackProjections[index], epoch = generation, validateFocus = self.validateFocus
        feedbackProjections.removeAll()
        hideFeedback()
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                guard try validateFocus(focus) else {
                    await MainActor.run { if self.generation == epoch { self.beginRouteCheck(); self.refreshRoute() } }
                    return
                }
                await MainActor.run {
                    guard self.enabled, self.generation == epoch, self.feedbackTarget == target,
                          self.session.feedbackTarget == target else { return }
                    self.readyFeedback = .selection(target, projection, focus)
                    do { try self.wake() } catch { self.stop(error) }
                }
            } catch {
                await MainActor.run {
                    guard self.generation == epoch, self.feedbackTarget == target else { return }
                    if let routeError = error as? DirectFocus.RouteError { self.routeFailed(routeError) }
                    else { self.stop(error) }
                }
            }
        }
    }

    private func applyFeedbackReady(_ proxy: CGEventTapProxy) throws {
        guard let result = readyFeedback else { return }
        readyFeedback = nil
        switch result {
        case .candidates(let target, let projections, let focus, let bounds):
            guard feedbackTarget == target, session.feedbackTarget == target else { return }
            guard focus.pid != getpid() else { reset(); return }
            feedbackFocus = focus
            feedbackProjections = projections
            showFeedback(projections.map { $0.text + target.separator }, bounds)
        case .selection(let target, let projection, _):
            guard feedbackTarget == target, let edit = session.applyFeedback(projection, for: target) else { return }
            try emit(edit, proxy)
            closeFeedback()
            let correct = self.correct
            Task.detached { [weak self] in
                guard let self else { return }
                do { try await correct(target, projection.text) }
                catch { await MainActor.run { self.stop(error) } }
            }
            requestDecision()
        }
    }

    private func applyReady(_ proxy: CGEventTapProxy) throws {
        guard !routeChecking else { return }
        guard let (request, text, target) = ready else { return }
        ready = nil
        guard session.snapshot == request else { requestDecision(); return }
        guard let route = textRoute, route.matches(target) else { beginRouteCheck(); refreshRoute(); return }
        if let focus, !focus.matches(target) {
            beginRouteCheck()
            refreshRoute()
            return
        }
        guard target.pid != getpid() else { reset(); return }
        focus = target
        if case .live(let current) = text {
            if !liveDetection {
                basicDecision = (request, current)
                lastDecided = session.snapshot
                return
            }
            guard let edit = session.accept(current, for: request) else { requestDecision(); return }
            try emit(edit, proxy)
            lastDecided = session.snapshot
            return
        }
        guard case .boundary(let result) = text else {
            throw DirectFailure(detail: "The completed-word decision is missing.")
        }
        guard let edit = try session.finish(result, for: request) else { return }
        try emit(edit, proxy)
        #if !DIRECT_INPUT_QA
        let language = session.preferredLanguage.rawValue
        preferencesQueue.async { UserDefaults.standard.set(language, forKey: "direct.preferredLanguage") }
        #endif
        requestDecision()
    }
}
