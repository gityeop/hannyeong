import AppKit
import ApplicationServices
import os
import Security

/// Main-run-loop cache; every AX request and subscription runs on its serial worker.
/// A key reads this cache only. Unknown/non-text routes never retain physical input.
final class InputRouteMonitor: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.yeop.Hannyeong.InputRoute", qos: .userInitiated)
    private let changed: (DirectFocus?, Bool, Set<Int64>) -> Void
    private let checking: () -> Void
    private let logger: Logger
    private var generation = 0
    private var probing = false
    private var stopped = true
    private var menuDepth = 0
    private var lastTextRoute: Bool?
    private var activePID: pid_t?
    private var textTarget: DirectFocus?
    // Worker-only ownership. Sources are installed on the main run loop.
    private var observers: [pid_t: AXObserver] = [:]
    private var keyboardSources: [pid_t: Bool] = [:]
    private var systemKeyboardPIDs: Set<Int64> = []

    init(sourceID: String, checking: @escaping () -> Void, changed: @escaping (DirectFocus?, Bool, Set<Int64>) -> Void) {
        self.checking = checking
        self.changed = changed
        logger = Logger(subsystem: sourceID, category: "InputRoute")
    }

    func start() {
        stopped = false
        activePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(producersChanged), name: name, object: nil)
        }
        refresh()
    }

    func invalidate() {
        textTarget = nil
        generation += 1
        changed(nil, false, systemKeyboardPIDs)
    }

    @objc private func producersChanged() { refresh() }

    @objc private func activationChanged(_ notification: Notification) {
        activePID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
        menuDepth = 0
        refresh()
    }

    func refresh() {
        guard !stopped else { return }
        generation += 1
        checking()
        guard !probing else { return }
        probe()
    }

    private func probe() {
        probing = true
        let epoch = generation
        let activePID = self.activePID
        queue.async { [self] in
            let result: Result<(DirectFocus.Probe, Set<Int64>), Error>
            do {
                let keyboardPIDs = try inspectKeyboardSources()
                let focus = try DirectFocus.probe()
                try watch(Set([activePID, focus.pid].compactMap { $0 }))
                result = .success((focus, keyboardPIDs))
            } catch { result = .failure(error) }
            DispatchQueue.main.async { [self] in
                probing = false
                guard !stopped else { return }
                guard generation == epoch else { probe(); return }
                switch result {
                case .success(let (focus, keyboardPIDs)):
                    systemKeyboardPIDs = keyboardPIDs
                    let target = menuDepth > 0 ? nil : focus.target
                    let isText = target != nil
                    if lastTextRoute != isText {
                        logger.notice("Input route classified; text=\(isText)")
                        lastTextRoute = isText
                    }
                    textTarget = target
                    changed(target, true, keyboardPIDs)
                case .failure(let error):
                    if let failure = error as? DirectFocus.RouteError { logger.error("Input route inspection failed: \(failure.detail, privacy: .public)") }
                    else if let failure = error as? DirectFailure { logger.error("Input route inspection failed: \(failure.detail, privacy: .public)") }
                    else { logger.error("Input route inspection failed: \(String(describing: error), privacy: .private)") }
                    checking()
                }
            }
        }
    }

    /// Source-role discovery runs on the route worker, never inside a key callback.
    /// Trust Apple's HID dispatcher entitlement, rather than the destination app's name.
    private func inspectKeyboardSources() throws -> Set<Int64> {
        let apps = NSWorkspace.shared.runningApplications
        let running = Set(apps.map(\.processIdentifier))
        keyboardSources = keyboardSources.filter { running.contains($0.key) }
        for app in apps where keyboardSources[app.processIdentifier] == nil {
            guard let url = app.bundleURL, url.path.hasPrefix("/System/") else {
                keyboardSources[app.processIdentifier] = false
                continue
            }
            var code: SecStaticCode?
            var requirement: SecRequirement?
            var info: CFDictionary?
            var status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
            guard status == errSecSuccess, let code else { throw DirectFailure(detail: "Inspecting keyboard source code failed (\(status)).") }
            status = SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement)
            guard status == errSecSuccess, let requirement else { throw DirectFailure(detail: "Creating the system keyboard requirement failed (\(status)).") }
            status = SecStaticCodeCheckValidity(code, [], requirement)
            guard status == errSecSuccess else { throw DirectFailure(detail: "Verifying system keyboard code failed (\(status)).") }
            status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
            guard status == errSecSuccess, let info else { throw DirectFailure(detail: "Reading keyboard source entitlements failed (\(status)).") }
            let entitlements = (info as NSDictionary)[kSecCodeInfoEntitlementsDict] as? [String: Any]
            keyboardSources[app.processIdentifier] = entitlements?["com.apple.private.hid.client.event-dispatch"] as? Bool == true
        }
        return Set(keyboardSources.compactMap { $0.value ? Int64($0.key) : nil })
    }

    private func watch(_ pids: Set<pid_t>) throws {
        for pid in Array(observers.keys) where !pids.contains(pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observers.removeValue(forKey: pid)!), .commonModes)
        }
        for pid in pids where observers[pid] == nil {
            var observer: AXObserver?
            let status = AXObserverCreate(pid, { _, element, notification, context in
                guard let context else { return }
                let monitor = Unmanaged<InputRouteMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.received(notification as String, element: element)
            }, &observer)
            guard status == .success, let observer else {
                throw DirectFailure(detail: "Creating an input route observer failed (AX \(status.rawValue)).")
            }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            for name in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
                         kAXWindowCreatedNotification, kAXUIElementDestroyedNotification,
                         kAXMenuOpenedNotification, kAXMenuClosedNotification] {
                let subscribed = AXObserverAddNotification(observer, app, name as CFString, Unmanaged.passUnretained(self).toOpaque())
                // These notifications are optional AX capabilities, not another input transport.
                guard subscribed == .success || subscribed == .notificationUnsupported || subscribed == .notImplemented else {
                    throw DirectFailure(detail: "Subscribing to input route changes failed (AX \(subscribed.rawValue)).")
                }
            }
            observers[pid] = observer
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }

    private func received(_ name: String, element: AXUIElement) {
        guard !stopped else { return }
        if name == kAXUIElementDestroyedNotification {
            // Search suggestions are destroyed on every edit. Only losing the owned
            // field or its window invalidates the keyboard route.
            guard let target = textTarget,
                  CFEqual(element, target.field) || CFEqual(element, target.window) else { return }
        }
        if name == kAXMenuOpenedNotification {
            menuDepth += 1
            if lastTextRoute != false { logger.notice("Input route classified; text=false menu=true") }
            lastTextRoute = false
            generation += 1
            textTarget = nil
            changed(nil, true, systemKeyboardPIDs)
        } else {
            if name == kAXMenuClosedNotification { menuDepth = max(0, menuDepth - 1) }
            refresh()
        }
    }

    func stop() {
        stopped = true
        invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        queue.async { [self] in
            for observer in observers.values {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
            observers.removeAll()
        }
    }
}
