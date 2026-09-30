import AppKit
import Foundation

@MainActor
final class AppServices {
    static let shared = AppServices()

    let model: AppModel
    private let driver: BackgroundDriver
    private let notifier = Notifier()

    private init() {
        model = AppModel(dataDirectory: AppPaths.dataDirectory, workDirectory: AppPaths.workDirectory)
        driver = BackgroundDriver(model: model)
        model.prepare()
    }

    func start() {
        guard !isSecondInstance else {
            NSApp.terminate(nil)
            return
        }
        model.onNotices = { [notifier] in notifier.post($0) }
        notifier.requestAuthorization()
        driver.start()
    }

    private var isSecondInstance: Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier).count > 1
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppServices.shared.start()
    }
}
