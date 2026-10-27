import HannyeongInputRuntime

/// Both input sources share system secure-input and local sudo password detection.
@MainActor
final class SecureInputSource {
    private let monitor = SecureInputMonitor(sourceID: "com.yeop.inputmethod.Hannyeong",
        entering: { NativeInputEngine.shared.reset() })
    func start() { monitor.start() }
    func stop() { monitor.stop() }
}
