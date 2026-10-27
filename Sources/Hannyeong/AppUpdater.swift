import Combine
import Sparkle

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    let controller: SPUStandardUpdaterController
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?

    init(delegate: SPUUpdaterDelegate? = nil) {
        controller = SPUStandardUpdaterController(startingUpdater: false,
                                                 updaterDelegate: delegate, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.lastUpdateCheckDate)
            .assign(to: &$lastUpdateCheckDate)
    }

    func start() {
        guard Bundle.main.object(forInfoDictionaryKey: "HannyeongLivePrototype") as? Bool != true else { return }
        controller.startUpdater()
    }
    func checkForUpdates() { controller.checkForUpdates(nil) }
}
