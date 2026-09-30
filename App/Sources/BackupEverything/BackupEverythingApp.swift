import SwiftUI

@main
struct BackupEverythingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppServices.shared.model

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarIcon()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("Backup Everything", id: MainWindow.id) {
            MainWindow()
                .environment(model)
        }
        .defaultSize(width: 1040, height: 680)
        .defaultLaunchBehavior(showsWindowAtLaunch ? .presented : .suppressed)
    }

    private var showsWindowAtLaunch: Bool {
        model.isFirstLaunch || CommandLine.arguments.contains("--show-window")
    }
}
