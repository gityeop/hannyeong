import Foundation
import Darwin

private final class ProbeSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var usedMainThread = false

    func next(_ pid: pid_t) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        usedMainThread = usedMainThread || Thread.isMainThread
        guard pid == 42 else { throw NSError(domain: "SudoPasswordMonitorQA", code: 2) }
        calls += 1
        switch calls {
        case 1, 3:
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM),
                userInfo: [NSLocalizedDescriptionKey: "Reading process metadata failed"])
        case 2: return true
        case 4: return false
        default: throw NSError(domain: "SudoPasswordMonitorQA", code: 3)
        }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var ranOnMainThread: Bool { lock.lock(); defer { lock.unlock() }; return usedMainThread }
}

@main private struct SudoPasswordMonitorQA {
    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("Sudo password monitor QA failed: \(error)\n", stderr); exit(1) }
    }

    @MainActor private static func run() async throws {
        let sequence = ProbeSequence()
        var changes = 0
        let monitor = SudoPasswordMonitor(probe: { try sequence.next($0) }) { changes += 1 }
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else {
                throw NSError(domain: "SudoPasswordMonitorQA", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: label])
            }
            print("PASS", label)
        }
        // Drive the same periodic refresh used in production. No retry loop
        // runs inside refresh or the keyboard callback.
        func poll(until condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            while !condition() {
                guard ContinuousClock.now < deadline else {
                    throw NSError(domain: "SudoPasswordMonitorQA", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "monitor did not recover"])
                }
                monitor.refresh(rootPID: 42, needed: true)
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await poll { monitor.active }
        try check(sequence.count == 2 && changes == 1,
            "metadata error does not disable later sudo detection")
        try await poll { !monitor.active }
        try check(sequence.count == 4 && changes == 2,
            "metadata error does not prevent detecting password completion")
        try check(!sequence.ranOnMainThread,
            "process and TTY probes stay off the main thread")
        monitor.stop()
        print("PASS sudo monitor recovery; no password or TTY contents read")
    }
}
