import AppKit
import Foundation

@MainActor
protocol BackgroundDriving {
    func start()
}

enum RunningCopies {
    static func isSecondInstance(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        count: (String) -> Int = { NSRunningApplication.runningApplications(withBundleIdentifier: $0).count }
    ) -> Bool {
        guard let bundleIdentifier else { return false }
        return count(bundleIdentifier) > 1
    }
}

@MainActor
final class AppServices {
    static let shared = AppServices()

    let model: AppModel
    private let driver: any BackgroundDriving
    private let notifier: any Notifying
    let isSecondInstance: Bool
    private let quit: () -> Void

    private convenience init() {
        let model = AppModel(dataDirectory: AppPaths.dataDirectory, workDirectory: AppPaths.workDirectory)
        self.init(
            model: model,
            driver: BackgroundDriver(model: model),
            notifier: Notifier(),
            isSecondInstance: { RunningCopies.isSecondInstance() },
            quit: { NSApp.terminate(nil) }
        )
    }

    /// A second copy prepares nothing: preparing clears the temporary folder of a backup the first copy may be running.
    init(
        model: AppModel,
        driver: any BackgroundDriving,
        notifier: any Notifying,
        isSecondInstance: @escaping () -> Bool,
        quit: @escaping () -> Void
    ) {
        self.model = model
        self.driver = driver
        self.notifier = notifier
        self.quit = quit
        self.isSecondInstance = isSecondInstance()
        guard !self.isSecondInstance else { return }
        model.prepare()
    }

    func start() {
        guard !isSecondInstance else {
            quit()
            return
        }
        model.onNotices = { [notifier] in notifier.post($0) }
        notifier.requestAuthorization()
        driver.start()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppServices.shared.start()
    }
}
