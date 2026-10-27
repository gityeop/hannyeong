import Foundation
import os

/// Main-actor cache. Process enumeration and TTY ioctls only run on the worker.
@MainActor
final class SudoPasswordMonitor {
    private let queue = DispatchQueue(label: "com.yeop.HannyeongDirect.SudoPassword", qos: .utility)
    private let probe: @Sendable (pid_t) throws -> Bool
    private let changed: @MainActor () -> Void
    private let logger = Logger(subsystem: "com.yeop.HannyeongInputRuntime", category: "SecureInput")
    private var rootPID: pid_t?
    private var generation = 0
    private var scanning = false
    private var needed = false
    private(set) var active = false

    init(probe: @escaping @Sendable (pid_t) throws -> Bool = { try SudoPasswordProbe.active(rootPID: $0) },
         changed: @escaping @MainActor () -> Void) {
        self.probe = probe
        self.changed = changed
    }

    func refresh(rootPID: pid_t?, needed: Bool) {
        if self.rootPID != rootPID || self.needed != needed {
            self.rootPID = rootPID
            self.needed = needed
            generation += 1
            setActive(false)
        }
        guard needed, let rootPID, !scanning else { return }
        scanning = true
        let epoch = generation
        let probe = self.probe
        queue.async { [weak self] in
            let result = Result { try probe(rootPID) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scanning = false
                guard self.generation == epoch, self.needed else { return }
                switch result {
                case .success(let active): self.setActive(active)
                case .failure(let error):
                    self.logger.error("Sudo password detection failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        logger.notice("Sudo password state active=\(active)")
        changed()
    }

    func stop() { generation += 1; needed = false; active = false }
}
